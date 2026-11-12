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
    }

    public static void main(String[] args) {
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

        if (modelPath == null || !Files.isRegularFile(Paths.get(modelPath))) {
            System.err.println("模型不存在: " + modelPath); System.exit(2);
        }
        if (j.blocks <= 0) { System.err.println("作业文件里没有 Export 块"); System.exit(2); }
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

            ModelUtil.initStandalone(false);

            boolean resume = Files.isRegularFile(solvedModel) && Files.isRegularFile(mkSolved);
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
            if (!resume) {
                System.out.println("[driver] 求解研究: " + j.study);
                System.out.flush();
                long t0 = System.currentTimeMillis();
                try {
                    model.study(j.study).run();
                } catch (Exception e) {
                    System.err.println("求解失败: " + e.getMessage()); System.exit(3);
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
                    System.exit(4);
                }
                System.out.println("[driver] 导出块 " + i + ": " + type + " / " + name);
                System.out.flush();
                try {
                    h.run(j, i);
                } catch (Exception e) {
                    System.err.println("导出块 " + name + " 失败: " + e.getMessage());
                    System.exit(4);
                }
            }

            Files.deleteIfExists(mkExporting);
            Files.write(mkExported, "ok".getBytes(StandardCharsets.UTF_8));
            System.out.println("[driver] 全部完成");
            System.exit(0);
        } catch (Exception e) {
            System.err.println("驱动异常: " + e);
            e.printStackTrace();
            System.exit(4);
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
            System.exit(2);
        }
        if (tags.length == 0) { System.err.println("模型里没有研究"); System.exit(2); }
        return tags[0];
    }

    static String firstDataset(Model model) {
        String[] ds = model.result().dataset().tags();
        if (ds.length == 0) { System.err.println("模型里没有数据集（研究可能没有求解）"); System.exit(4); }
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
