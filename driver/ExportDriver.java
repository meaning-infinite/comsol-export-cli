// COMSOL 导出驱动
// 打开模型副本 -> 跑研究 -> 按作业文件里的 Export 块，交给对应 handler 处理。
// 不读参数、不改参数、不改网格；模型里存什么就算什么。
//
// 用法: ExportDriver <job.properties>
// 作业文件键值：
//   model / study / outdir / outname / modelsdir / blocks
//   block.N.type   global | spectrum | image | eigenslice
//   block.N.name   文件名后缀
//   其余键按类型解释，见各 handler 注释。
//
// 退出码: 0 成功; 2 用法/文件错误; 3 求解失败; 4 导出失败

import com.comsol.model.Model;
import com.comsol.model.util.ModelUtil;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;

public class ExportDriver {

    // ---------- 作业上下文 ----------
    static class Job {
        Map<String, String> p;
        Path jobDir, outdir, modelsDir;
        String outname, dataset, study;
        int blocks;
        Model model;
        String[] pnames = new String[0];
        boolean single() { return blocks == 1; }
        String block(int i, String key, String def) {
            return p.getOrDefault("block." + i + "." + key, def);
        }
        String[] blockArr(int i, String key) {
            return split(p.getOrDefault("block." + i + "." + key, ""));
        }
    }

    interface Handler { void run(Job j, int i) throws Exception; }

    static final Map<String, Handler> HANDLERS = new LinkedHashMap<>();

    static {
        HANDLERS.put("global", ExportDriver::exportGlobal);   // 表达式取数 -> CSV
        HANDLERS.put("spectrum", ExportDriver::exportSpectrum); // 透射/反射谱 CSV + 可选曲线图
        HANDLERS.put("image", ExportDriver::exportImage);     // 单张多切面图
        HANDLERS.put("eigenslice", ExportDriver::exportEigenSlice); // 每个特征频率 3 张切面图
        HANDLERS.put("slice2d", ExportDriver::exportSlice2D);   // 多切面二维正投影图
        HANDLERS.put("integral", ExportDriver::exportIntegral); // 线/面积分 -> CSV
        HANDLERS.put("modes", ExportDriver::exportModes);       // 特征频率数值 -> CSV
    }

    static String stackOf(Throwable t) {
        java.io.StringWriter sw = new java.io.StringWriter();
        t.printStackTrace(new java.io.PrintWriter(sw));
        return sw.toString();
    }

    static Path CURRENT_JOB_DIR = null;
    static Path LOG_FILE = null;

    // 自带日志：不依赖 stdout 重定向（stdout 句柄异常时会全部丢失），每行立即落盘
    static void log(String s) {
        System.out.println(s);
        System.out.flush();
        if (LOG_FILE != null) {
            try {
                Files.write(LOG_FILE, (s + System.lineSeparator()).getBytes(StandardCharsets.UTF_8),
                        StandardOpenOption.CREATE, StandardOpenOption.APPEND);
            } catch (Exception ignore) { }
        }
    }

    // 统一收尾：写 exit 标记（CLI 靠它判断退出码），刷 stdout/stderr，再退出
    static void finish(Path jobDir, int code) {
        if (jobDir != null) {
            try {
                Files.write(jobDir.resolve("exit"), String.valueOf(code).getBytes(StandardCharsets.UTF_8));
            } catch (IOException ignore) { }
        }
        System.out.flush();
        System.err.flush();
        System.exit(code);
    }

    public static void main(String[] args) {
        // 控制台被重定向时 Java 默认不自动 flush，进程被杀就看得到 0 字节日志；这里强制 UTF-8 + 自动 flush
        try {
            System.setOut(new PrintStream(new FileOutputStream(FileDescriptor.out), true, "UTF-8"));
            System.setErr(new PrintStream(new FileOutputStream(FileDescriptor.err), true, "UTF-8"));
        } catch (Exception ignore) { }
        if (args.length < 1) { System.err.println("usage: ExportDriver <job.properties>"); System.exit(2); }

        Job j = new Job();
        try {
            j.p = readSpec(Paths.get(args[0]));
        } catch (IOException e) {
            System.err.println("读作业文件失败: " + e.getMessage()); System.exit(2); return;
        }
        String modelPath = j.p.get("model");
        String outdir = j.p.get("outdir");
        j.outname = j.p.get("outname");
        j.blocks = Integer.parseInt(j.p.getOrDefault("blocks", "0").trim());
        j.jobDir = Paths.get(args[0]).toAbsolutePath().getParent();
        CURRENT_JOB_DIR = j.jobDir;
        LOG_FILE = j.jobDir.resolve("driver.self.log");
        log("[driver] 启动 pid=" + ProcessHandle.current().pid() + " java=" + System.getProperty("java.version"));
        try {
            Files.write(j.jobDir.resolve("started"),
                    ("pid=" + ProcessHandle.current().pid()).getBytes(StandardCharsets.UTF_8));
            log("[driver] 已写 started 标记");
        } catch (IOException ignore) { }

        if (modelPath == null || !Files.isRegularFile(Paths.get(modelPath))) {
            System.err.println("模型不存在: " + modelPath); finish(j.jobDir, 2);
        }
        if (j.blocks <= 0) { System.err.println("作业文件里没有 Export 块"); finish(j.jobDir, 2); }
        j.outdir = Paths.get(outdir).toAbsolutePath();

        String modelsDirProp = j.p.getOrDefault("modelsdir", "").trim();
        j.modelsDir = modelsDirProp.isEmpty()
                ? j.outdir.getParent().resolve("models")
                : Paths.get(modelsDirProp).toAbsolutePath();
        Path solvedModel = j.modelsDir.resolve("solved").resolve(j.outname + ".mph");
        if (!Files.isRegularFile(solvedModel)) {
            Path legacy = j.jobDir.resolve("solved.mph");
            if (Files.isRegularFile(legacy)) solvedModel = legacy;
        }
        Path mkSolved = j.jobDir.resolve("solved");
        Path mkExporting = j.jobDir.resolve("exporting");
        Path mkExported = j.jobDir.resolve("exported");

        Path tmp = null;
        try {
            tmp = Files.createTempDirectory("comsol-export-");
            Path copy = tmp.resolve("model.mph");
            Files.copy(Paths.get(modelPath), copy, StandardCopyOption.REPLACE_EXISTING);
            log("[driver] 已拷模型到临时目录");

            log("[driver] 初始化 COMSOL (initStandalone)…");
            ModelUtil.initStandalone(false);
            log("[driver] COMSOL 初始化完成");

            String solveFlag = j.p.getOrDefault("solve", "1").trim();
            boolean doSolve = !("0".equals(solveFlag) || "false".equalsIgnoreCase(solveFlag));
            boolean resume = doSolve && Files.isRegularFile(solvedModel) && Files.isRegularFile(mkSolved);
            Model model;
            try {
                if (resume) {
                    System.out.println("[driver] 续跑：加载已求解的模型 " + solvedModel);
                    model = ModelUtil.load("m_export", solvedModel.toString());
                } else {
                    System.out.println("[driver] 打开模型副本: " + copy);
                    model = ModelUtil.load("m_export", copy.toString());
                }
            } catch (Exception ex) {
                String m = String.valueOf(ex.getMessage());
                if (m.contains("later version")) {
                    throw new RuntimeException("模型是由更高版本 COMSOL 创建的，当前驱动版本打不开。请用 -Setup [1] 选择与模型匹配的 COMSOL 版本后重试。");
                }
                throw ex;
            }
            j.model = model;
            System.out.flush();

            j.study = resolveStudy(model, j.p.getOrDefault("study", ""));
            if (!doSolve) {
                System.out.println("[driver] 只导出：模型里已有解，跳过求解");
                Files.write(mkExporting, "ok".getBytes(StandardCharsets.UTF_8));
            } else if (!resume) {
                System.out.println("[driver] 求解研究: " + j.study);
                System.out.flush();
                long t0 = System.currentTimeMillis();
                log("[driver] heap max=" + (Runtime.getRuntime().maxMemory() / 1048576) + "MB");
                try {
                    log("[driver] 开始求解 (study=" + j.study + ")…");
                    model.study(j.study).run();
                    log("[driver] 求解结束");
                } catch (Throwable e) {
                    log("[driver] 求解异常: " + e);
                    log(stackOf(e));
                    finish(j.jobDir, 3);
                }
                System.out.println("[driver] 求解完成，耗时 " + (System.currentTimeMillis() - t0) / 1000 + " s");
                System.out.flush();
                Files.createDirectories(solvedModel.getParent());
                model.save(solvedModel.toString());
                System.out.println("[driver] 已求解模型: " + solvedModel);
                Files.write(mkSolved, "ok".getBytes(StandardCharsets.UTF_8));
            } else {
                System.out.println("[driver] 续跑：跳过求解");
            }
            Files.write(mkExporting, "ok".getBytes(StandardCharsets.UTF_8));

            j.dataset = firstDataset(model);
            j.pnames = studyParamNames(model, j.study);
            if (j.pnames.length > 0) {
                System.out.println("[driver] 参数化扫描变量: " + String.join(", ", j.pnames));
                System.out.flush();
            }
            Files.createDirectories(j.outdir);

            for (int i = 1; i <= j.blocks; i++) {
                String type = j.block(i, "type", "global").trim().toLowerCase();
                String name = j.block(i, "name", "export" + i).trim();
                Handler h = HANDLERS.get(type);
                if (h == null) {
                    System.err.println("暂不支持的导出类型: " + type + "（可用: " + String.join(", ", HANDLERS.keySet()) + "）");
                    finish(j.jobDir, 4);
                }
                System.out.println("[driver] 导出块 " + i + ": " + type + " / " + name);
                System.out.flush();
                try {
                    h.run(j, i);
                } catch (Exception e) {
                    System.err.println("导出块 " + name + " 失败: " + e.getMessage());
                    finish(j.jobDir, 4);
                }
            }

            Files.deleteIfExists(mkExporting);
            Files.write(mkExported, "ok".getBytes(StandardCharsets.UTF_8));
            System.out.println("[driver] 全部完成");
            finish(j.jobDir, 0);
        } catch (Throwable e) {
            log("[driver] 驱动异常: " + e);
            log(stackOf(e));
            System.err.println("驱动异常: " + e);
            e.printStackTrace();
            finish(j.jobDir, 4);
        } finally {
            try { ModelUtil.clear(); } catch (Exception ignore) { }
            if (tmp != null) { try { deleteTree(tmp); } catch (Exception ignore) { } }
        }
    }

    // ---------- global / spectrum ----------
    // expr / cols：| 分隔；扫描变量自动前置两列
    static void exportGlobal(Job j, int i) throws Exception {
        String name = j.block(i, "name", "export" + i);
        String[] expr0 = j.blockArr(i, "expr");
        String[] cols0 = j.blockArr(i, "cols");
        if (expr0.length == 0 || cols0.length != expr0.length) {
            throw new IllegalStateException("expr/cols 数量不匹配");
        }
        int m = j.pnames.length;
        String[] expr = new String[m + expr0.length];
        String[] cols = new String[m + cols0.length];
        for (int k = 0; k < m; k++) { expr[k] = j.pnames[k]; cols[k] = j.pnames[k]; }
        System.arraycopy(expr0, 0, expr, m, expr0.length);
        System.arraycopy(cols0, 0, cols, m, cols0.length);

        List<double[]> found = new ArrayList<>();
        String node = "gev_export_" + i;
        j.model.result().numerical().create(node, "EvalGlobal");
        j.model.result().numerical(node).set("data", j.dataset);
        j.model.result().numerical(node).set("expr", expr);
        j.model.result().numerical(node).set("descr", cols);
        for (String solTag : j.model.sol().tags()) {
            j.model.result().dataset(j.dataset).set("solution", solTag);
            for (int k = 1; k <= 200; k++) {
                try {
                    j.model.result().numerical(node).set("solnum", Integer.toString(k));
                    double[][] a = j.model.result().numerical(node).getReal();
                    if (a.length == 0 || a[0].length == 0) break;
                    double[] row = new double[expr.length];
                    boolean ok = true;
                    for (int q = 0; q < expr.length; q++) {
                        double v = a[q][0];
                        if (Double.isNaN(v)) ok = false;
                        row[q] = v;
                    }
                    if (!ok) continue;
                    boolean dup = false;
                    for (double[] prev : found) if (Arrays.equals(prev, row)) { dup = true; break; }
                    if (!dup) found.add(row);
                } catch (Exception inner) { break; }
            }
        }
        if (found.isEmpty()) throw new IllegalStateException("没有取到任何解（检查解节点与表达式）");

        double[][] data = new double[expr.length][found.size()];
        for (int c = 0; c < found.size(); c++)
            for (int q = 0; q < expr.length; q++) data[q][c] = found.get(c)[q];
        System.out.println("[driver] 共取到 " + found.size() + " 个解");

        Path target = csvTarget(j, i, name);
        writeCsv(target, data, expr, cols);
        System.out.println("[driver] 写出 " + target);
    }

    // spectrum：透射/反射谱（CSV 必出，曲线图可选 Plot=true）
    static void exportSpectrum(Job j, int i) throws Exception {
        String name = j.block(i, "name", "spectrum");
        if (j.block(i, "expr", "").trim().isEmpty()) {
            j.p.put("block." + i + ".expr", "c_const/ewfd.freq|abs(ewfd.S21)^2|abs(ewfd.S11)^2");
            j.p.put("block." + i + ".cols", "lambda_nm|T|R");
        }
        exportGlobal(j, i);
        if ("true".equalsIgnoreCase(j.block(i, "plot", "false").trim())) {
            exportCurve(j, i, name);
        }
    }

    static void exportCurve(Job j, int i, String name) throws Exception {
        String tag = "pg1d_" + i;
        j.model.result().create(tag, "PlotGroup1D");
        j.model.result(tag).set("data", j.dataset);
        j.model.result(tag).create("glob1", "Global");
        String[] expr = { "abs(ewfd.S21)^2", "abs(ewfd.S11)^2" };
        j.model.result(tag).feature("glob1").set("expr", expr);
        j.model.result(tag).feature("glob1").set("descr", new String[] { "T", "R" });
        try { j.model.result(tag).set("title", name); } catch (Exception ignore) { }
        j.model.result(tag).run();
        Path png = j.outdir.resolve(j.outname + "_" + name + ".png");
        exportPng(j, i, tag, png);
        System.out.println("[driver] 写出 " + png);
    }

    // ---------- image ----------
    // expr（默认 ewfd.normE）、plane（xy|zx|yz，默认 xy）、at（切面位置，默认 0）、
    // solnum（默认 1）、width/height（像素，默认 800x600）、title
    static void exportImage(Job j, int i) throws Exception {
        String name = j.block(i, "name", "image");
        String tag = "pg_img_" + i;
        buildSliceGroup(j, i, tag);
        String solnum = j.block(i, "solnum", "1").trim();
        try { j.model.result(tag).set("solnum", solnum); } catch (Exception ignore) { }
        j.model.result(tag).run();
        Path png = j.outdir.resolve(j.outname + "_" + name + ".png");
        exportPng(j, i, tag, png);
        System.out.println("[driver] 写出 " + png);
    }

    // ---------- eigenslice ----------
    // 每个特征频率解 -> 3 张切面图（xy / zx / yz），文件名 <outname>_m<k>_<plane>.png
    // planes（默认 xy|zx|yz）、expr、at、width/height、maxmodes（默认 50）
    static void exportEigenSlice(Job j, int i) throws Exception {
        String expr = j.block(i, "expr", "ewfd.normE").trim();
        String[] planes = j.block(i, "planes", "xy|zx|yz").trim().split("\\|");
        int maxModes = Integer.parseInt(j.block(i, "maxmodes", "50").trim());
        String tag = "pg_eig_" + i;
        buildSliceGroup(j, i, tag);
        j.model.result(tag).feature("sli1").set("expr", expr);
        int written = 0;
        String[] solTags = j.model.sol().tags();
        boolean multiSol = solTags.length > 1;
        int solIdx = 0;
        for (String solTag : solTags) {
            solIdx++;
            String dset = "dset_eig_" + i + "_" + solTag;
            if (!Arrays.asList(j.model.result().dataset().tags()).contains(dset)) {
                j.model.result().dataset().create(dset, "Solution");
            }
            j.model.result().dataset(dset).set("solution", solTag);
            j.model.result(tag).set("data", dset);
            for (int k = 1; k <= maxModes; k++) {
                try {
                    j.model.result(tag).set("solnum", Integer.toString(k));
                } catch (Exception ex) { break; }
                boolean any = false;
                for (String plane : planes) {
                    try {
                        j.model.result(tag).feature("sli1").set("quickplane", plane.trim());
                        j.model.result(tag).feature("sli1").set(offsetKey(plane.trim()), j.block(i, "at", "0").trim());
                        j.model.result(tag).run();
                        String mid = multiSol ? ("_s" + solIdx + "_m" + k) : ("_m" + k);
                        Path png = j.outdir.resolve(j.outname + mid + "_" + plane.trim() + ".png");
                        exportPng(j, i, tag, png);
                        System.out.println("[driver] 写出 " + png);
                        written++; any = true;
                    } catch (Exception ex) {
                        System.out.println("[driver] 模式 " + k + " 平面 " + plane + " 跳过: " + ex.getMessage());
                    }
                }
                if (!any) break;
            }
        }
        if (written == 0) throw new IllegalStateException("没有导出任何特征频率切片（检查是否有特征频率解）");
    }

    // ---------- slice2d：多切面二维正投影 ----------
    static void exportSlice2D(Job j, int i) throws Exception {
        String name = j.block(i, "name", "slice2d");
        String[] planes = j.blockArr(i, "planes");
        if (planes.length == 0) planes = new String[] { "xy", "zx", "yz" };
        String expr = j.block(i, "expr", "ewfd.normE").trim();
        String at = j.block(i, "at", "auto").trim();
        double[] bb = j.model.component("comp1").geom("geom1").getBoundingBox();
        String gunit = "m";
        try { gunit = j.model.component("comp1").geom("geom1").lengthUnit(); } catch (Exception ignore) { }
        double gf = unitFactor(gunit);
        for (String raw : planes) {
            String plane = raw.trim().toLowerCase(Locale.ROOT);
            if (!plane.equals("xy") && !plane.equals("yz") && !plane.equals("zx")) {
                throw new IllegalStateException("平面只能是 xy / zx / yz：" + plane);
            }
            String dtag = "dsp2d_" + i + "_" + plane;
            if (!Arrays.asList(j.model.result().dataset().tags()).contains(dtag)) {
                j.model.result().dataset().create(dtag, "CutPlane");
            }
            j.model.result().dataset(dtag).set("data", j.dataset);
            j.model.result().dataset(dtag).set("quickplane", plane);
            String pos = at;
            if (pos.isEmpty() || pos.equalsIgnoreCase("auto")) {
                if (plane.equals("xy")) pos = Double.toString((bb[2] + bb[5]) / 2 * gf);
                else if (plane.equals("zx")) pos = Double.toString((bb[1] + bb[4]) / 2 * gf);
                else pos = Double.toString((bb[0] + bb[3]) / 2 * gf);
            }
            j.model.result().dataset(dtag).set(offsetKey(plane), pos);

            String pg = "pg2d_" + i + "_" + plane;
            if (!Arrays.asList(j.model.result().tags()).contains(pg)) {
                j.model.result().create(pg, "PlotGroup2D");
            }
            j.model.result(pg).set("data", dtag);
            if (!Arrays.asList(j.model.result(pg).feature().tags()).contains("surf1")) {
                j.model.result(pg).create("surf1", "Surface");
            }
            j.model.result(pg).feature("surf1").set("expr", expr);
            String title = j.block(i, "title", "").trim();
            if (!title.isEmpty()) { try { j.model.result(pg).set("title", title + " " + plane); } catch (Exception ignore) { } }
            j.model.result(pg).run();
            Path png = j.outdir.resolve(j.outname + "_" + name + "_" + plane + ".png");
            exportPng(j, i, pg, png);
            System.out.println("[driver] 写出 " + png);
        }
    }

    // ---------- integral：线积分 / 面积分 ----------
    static void exportIntegral(Job j, int i) throws Exception {
        String name = j.block(i, "name", "integral");
        String dim = j.block(i, "dim", "surface").trim().toLowerCase(Locale.ROOT);
        String ents = j.block(i, "ents", "all").trim();
        String[] expr = j.blockArr(i, "expr");
        String[] cols = j.blockArr(i, "cols");
        if (expr.length == 0) { expr = new String[] { "ewfd.normE" }; }
        if (cols.length != expr.length) throw new IllegalStateException("expr/cols 数量不匹配");
        String node = "int_" + i;
        String type = dim.equals("line") ? "IntLine" : "IntSurface";
        if (!Arrays.asList(j.model.result().numerical().tags()).contains(node)) {
            j.model.result().numerical().create(node, type);
        }
        j.model.result().numerical(node).set("data", j.dataset);
        j.model.result().numerical(node).set("expr", expr);
        j.model.result().numerical(node).set("descr", cols);
        if (ents.isEmpty() || ents.equalsIgnoreCase("all")) {
            j.model.result().numerical(node).selection().all();
        } else {
            java.util.List<Integer> tmp = new ArrayList<>();
            for (String s : ents.split(",")) {
                String x = s.trim();
                if (!x.isEmpty()) tmp.add(Integer.valueOf(x));
            }
            int[] ids = new int[tmp.size()];
            for (int q = 0; q < ids.length; q++) ids[q] = tmp.get(q);
            try {
                j.model.result().numerical(node).selection().set(ids);
            } catch (Exception e) {
                throw new IllegalStateException("实体编号不存在（" + dim + "）: " + ents + " — " + e.getMessage());
            }
        }
        List<double[]> found = evalAll(j, node, expr.length, 200);
        if (found.isEmpty()) throw new IllegalStateException("积分没有取到任何值（检查实体编号与表达式）");
        double[][] data = new double[expr.length][found.size()];
        for (int c = 0; c < found.size(); c++)
            for (int q = 0; q < expr.length; q++) data[q][c] = found.get(c)[q];
        Path target = csvTarget(j, i, name);
        writeCsv(target, data, expr, cols);
        System.out.println("[driver] 写出 " + target);
    }

    // ---------- modes：每个模态一行数值 ----------
    static void exportModes(Job j, int i) throws Exception {
        String name = j.block(i, "name", "modes");
        String[] expr = j.blockArr(i, "expr");
        String[] cols = j.blockArr(i, "cols");
        if (expr.length == 0) { expr = new String[] { "ewfd.freq" }; cols = new String[] { "freq" }; }
        if (cols.length != expr.length) throw new IllegalStateException("expr/cols 数量不匹配");
        int maxModes = Integer.parseInt(j.block(i, "maxmodes", "50").trim());
        String node = "gmod_" + i;
        if (!Arrays.asList(j.model.result().numerical().tags()).contains(node)) {
            j.model.result().numerical().create(node, "EvalGlobal");
        }
        j.model.result().numerical(node).set("data", j.dataset);
        j.model.result().numerical(node).set("expr", expr);
        j.model.result().numerical(node).set("descr", cols);
        List<double[]> rows = new ArrayList<>();
        for (String solTag : j.model.sol().tags()) {
            j.model.result().dataset(j.dataset).set("solution", solTag);
            for (int k = 1; k <= maxModes; k++) {
                try {
                    j.model.result().numerical(node).set("solnum", Integer.toString(k));
                    double[][] a = j.model.result().numerical(node).getReal();
                    if (a.length == 0 || a[0].length == 0) break;
                    double[] row = new double[expr.length + 1];
                    boolean ok = true;
                    for (int q = 0; q < expr.length; q++) {
                        double v = a[q][0];
                        if (Double.isNaN(v) || Double.isInfinite(v)) { ok = false; break; }
                        row[q + 1] = v;
                    }
                    if (!ok) break;
                    boolean dup = false;
                    for (double[] prev : rows) {
                        boolean same = true;
                        for (int q = 1; q < row.length; q++) if (prev[q] != row[q]) { same = false; break; }
                        if (same) { dup = true; break; }
                    }
                    if (dup) continue;
                    row[0] = rows.size() + 1;
                    rows.add(row);
                } catch (Exception inner) { break; }
            }
        }
        if (rows.isEmpty()) throw new IllegalStateException("没有取到任何模态（检查解节点与表达式）");
        String[] allExpr = new String[expr.length + 1];
        String[] allCols = new String[expr.length + 1];
        allExpr[0] = "mode"; allCols[0] = "mode";
        System.arraycopy(expr, 0, allExpr, 1, expr.length);
        System.arraycopy(cols, 0, allCols, 1, cols.length);
        double[][] data = new double[allExpr.length][rows.size()];
        for (int c = 0; c < rows.size(); c++)
            for (int q = 0; q < allExpr.length; q++) data[q][c] = rows.get(c)[q];
        Path target = csvTarget(j, i, name);
        writeCsv(target, data, allExpr, allCols);
        System.out.println("[driver] 写出 " + target);
    }

    // 遍历所有解节点与解编号取数，按行去重（积分/模态共用）
    static List<double[]> evalAll(Job j, String node, int nExpr, int maxSol) throws Exception {
        List<double[]> found = new ArrayList<>();
        for (String solTag : j.model.sol().tags()) {
            j.model.result().dataset(j.dataset).set("solution", solTag);
            for (int k = 1; k <= maxSol; k++) {
                try {
                    j.model.result().numerical(node).set("solnum", Integer.toString(k));
                    double[][] a = j.model.result().numerical(node).getReal();
                    if (a.length == 0 || a[0].length == 0) break;
                    double[] row = new double[nExpr];
                    boolean ok = true;
                    for (int q = 0; q < nExpr; q++) {
                        double v = a[q][0];
                        if (Double.isNaN(v) || Double.isInfinite(v)) { ok = false; break; }
                        row[q] = v;
                    }
                    if (!ok) continue;
                    boolean dup = false;
                    for (double[] prev : found) if (Arrays.equals(prev, row)) { dup = true; break; }
                    if (!dup) found.add(row);
                } catch (Exception inner) { break; }
            }
        }
        return found;
    }

    static double unitFactor(String u) {
        String s = u == null ? "m" : u.trim().toLowerCase(Locale.ROOT);
        if (s.equals("nm")) return 1e-9;
        if (s.equals("um") || s.equals("\u00b5m")) return 1e-6;
        if (s.equals("mm")) return 1e-3;
        if (s.equals("cm")) return 1e-2;
        if (s.equals("km")) return 1e3;
        if (s.equals("in")) return 0.0254;
        return 1.0;
    }

    static String offsetKey(String plane) {
        if ("xy".equals(plane)) return "quickz";
        if ("zx".equals(plane)) return "quicky";
        return "quickx";
    }

    static void buildSliceGroup(Job j, int i, String tag) throws Exception {
        j.model.result().create(tag, "PlotGroup3D");
        j.model.result(tag).set("data", j.dataset);
        j.model.result(tag).create("sli1", "Slice");
        String plane = j.block(i, "plane", "xy").trim();
        j.model.result(tag).feature("sli1").set("quickplane", plane);
        j.model.result(tag).feature("sli1").set(offsetKey(plane), j.block(i, "at", "0").trim());
        j.model.result(tag).feature("sli1").set("expr", j.block(i, "expr", "ewfd.normE").trim());
        String title = j.block(i, "title", "").trim();
        if (!title.isEmpty()) { try { j.model.result(tag).set("title", title); } catch (Exception ignore) { } }
    }

    static void exportPng(Job j, int i, String plotGroup, Path target) throws Exception {
        String tag = "img_" + i + "_" + Math.abs((plotGroup + target.toString()).hashCode() % 1000000);
        if (!Arrays.asList(j.model.result().export().tags()).contains(tag)) {
            j.model.result().export().create(tag, "Image");
        }
        j.model.result().export(tag).set("plotgroup", plotGroup);
        j.model.result().export(tag).set("imagetype", "png");
        j.model.result().export(tag).set("size", "manualweb");
        j.model.result().export(tag).set("unit", "px");
        j.model.result().export(tag).set("width", j.block(i, "width", "800").trim());
        j.model.result().export(tag).set("height", j.block(i, "height", "600").trim());
        Path part = Paths.get(target.toString() + ".part.png");
        j.model.result().export(tag).set("pngfilename", part.toString().replace("\\", "/"));
        Files.createDirectories(target.getParent());
        j.model.result().export(tag).run();
        Files.move(part, target, StandardCopyOption.REPLACE_EXISTING);
    }

    static Path csvTarget(Job j, int i, String name) {
        String base = j.single() ? j.outname : j.outname + "_" + name;
        return j.outdir.resolve(base + ".csv");
    }

    // ---------- 工具 ----------
    static Map<String, String> readSpec(Path file) throws IOException {
        String text = new String(Files.readAllBytes(file), StandardCharsets.UTF_8);
        if (!text.isEmpty() && text.charAt(0) == '\uFEFF') text = text.substring(1);
        Map<String, String> map = new LinkedHashMap<>();
        for (String line : text.split("\r?\n")) {
            String s2 = line.trim();
            if (s2.isEmpty() || s2.startsWith("#")) continue;
            int i = s2.indexOf('=');
            if (i <= 0) continue;
            map.put(s2.substring(0, i).trim(), s2.substring(i + 1).trim());
        }
        return map;
    }

    static String[] studyParamNames(Model model, String study) {
        List<String> names = new ArrayList<>();
        try {
            for (String ft : model.study(study).feature().tags()) {
                if (!"Parametric".equals(model.study(study).feature(ft).getType())) continue;
                String[] pn = model.study(study).feature(ft).getStringArray("pname");
                for (String s : pn) for (String piece : s.split(",")) {
                    String q = piece.trim();
                    if (!q.isEmpty() && !names.contains(q)) names.add(q);
                }
            }
        } catch (Exception ignore) { }
        return names.toArray(new String[0]);
    }

    static String resolveStudy(Model model, String want) {
        String[] tags = model.study().tags();
        if (want != null && !want.isEmpty()) {
            for (String t : tags) if (t.equals(want)) return t;
            System.err.println("模型里没有研究 '" + want + "'，可用: " + String.join(", ", tags));
            finish(CURRENT_JOB_DIR, 2);
        }
        if (tags.length == 0) { System.err.println("模型里没有研究"); finish(CURRENT_JOB_DIR, 2); }
        return tags[0];
    }

    static String firstDataset(Model model) {
        String[] ds = model.result().dataset().tags();
        if (ds.length == 0) { System.err.println("模型里没有数据集（研究可能没有求解）"); finish(CURRENT_JOB_DIR, 4); }
        return ds[0];
    }

    static String[] split(String s) {
        if (s == null || s.trim().isEmpty()) return new String[0];
        return s.split("\\|", -1);
    }

    static void writeCsv(Path target, double[][] data, String[] expr, String[] cols) throws IOException {
        Path part = Paths.get(target.toString() + ".part");
        try (BufferedWriter w = Files.newBufferedWriter(part, StandardCharsets.UTF_8)) {
            w.write(String.join(",", cols));
            w.newLine();
            int nPoints = (data.length > 0) ? data[0].length : 0;
            for (int c = 0; c < nPoints; c++) {
                StringBuilder sb = new StringBuilder();
                for (int q = 0; q < data.length; q++) {
                    if (q > 0) sb.append(',');
                    double v = data[q][c];
                    if (q == 0 && cols[0].endsWith("_nm") && expr[0].trim().startsWith("c_const/")) {
                        double nm = (Math.abs(v) < 1.0) ? v * 1e9 : v;
                        sb.append(String.format(Locale.ROOT, "%.2f", nm));
                    } else {
                        sb.append(String.format(Locale.ROOT, "%.6g", v));
                    }
                }
                w.write(sb.toString());
                w.newLine();
            }
        }
        Files.move(part, target, StandardCopyOption.REPLACE_EXISTING);
    }

    static void deleteTree(Path root) throws IOException {
        if (!Files.exists(root)) return;
        Files.walk(root).sorted(Comparator.reverseOrder()).forEach(p -> {
            try { Files.deleteIfExists(p); } catch (IOException ignore) { }
        });
    }
}
