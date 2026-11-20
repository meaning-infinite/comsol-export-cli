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
        List<SolUse> sols = new ArrayList<>();
        int chunk = 200;
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
        HANDLERS.put("bigtable", ExportDriver::exportBigTable); // 通用原始大表（参数+谱线+域吸收）
    }

    static String stackOf(Throwable t) {
        java.io.StringWriter sw = new java.io.StringWriter();
        t.printStackTrace(new java.io.PrintWriter(sw));
        return sw.toString();
    }

    static Path CURRENT_JOB_DIR = null;
    static Path LOG_FILE = null;
    static Path PROGRESS_FILE = null;
    static String PROGRESS_LABEL = "导出";

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

    // 进度落盘：CLI 靠它显示「已取 x/N」。先写 progress.tmp 再改名，避免 CLI 读到半行。
    static void progress(int done, int total, String label) {
        if (PROGRESS_FILE == null) return;
        String s = "done=" + done + "\ntotal=" + total + "\nlabel=" + label
                + "\nts=" + System.currentTimeMillis() + "\n";
        try {
            Path tmp = PROGRESS_FILE.resolveSibling("progress.tmp");
            Files.write(tmp, s.getBytes(StandardCharsets.UTF_8));
            Files.move(tmp, PROGRESS_FILE, StandardCopyOption.REPLACE_EXISTING);
        } catch (Exception ignore) { }
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
        // 注意：不要用 new FileOutputStream(FileDescriptor.out) 重建 System.out ——
        // 某些机器上该句柄不可用，会静默把输出丢光（远程曾出现 driver.log 恒为 0B）。
        // 编码由 -Dfile.encoding=UTF-8 保证；日志另写 driver.self.log。
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
        PROGRESS_FILE = j.jobDir.resolve("progress.txt");
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

            // 先清点解：每个解节点有多少个解，后面按块逐解取数并逐块校验列数
            j.chunk = chunkSize(j);
            j.sols = listSols(j);
            int totSols = 0;
            for (SolUse u : j.sols) {
                System.out.println("[driver] 解节点 " + u.tag + (u.n > 0 ? ": " + u.n + " 个解" : ": 无可用解"));
                if (u.n > 0) totSols += u.n;
            }
            System.out.println("[driver] 待导出解数 " + totSols + "，分块 " + j.chunk
                    + "，heap max=" + (Runtime.getRuntime().maxMemory() >> 20) + "MB");
            if (totSols == 0) {
                System.out.println("[driver] 警告: 模型里没有可用的解（没求解过？先用 solve=1 跑研究）");
            }
            System.out.flush();
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
                PROGRESS_LABEL = "导出块 " + i + "/" + j.blocks + " " + name;
                progress(0, totSols, PROGRESS_LABEL);
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

    // ---------- 逐解取数核心 ----------
    // 为什么不直接用“所有解”(innerinput=all) 一次取完：
    // 远程 651 个解（λ 400→1050 步 1）的模型只写出了前 400 行。COMSOL 在解多、堆紧张时
    // 会静默少给列，而旧代码对 NaN 一律 continue 跳过，于是短表被当成正常结果落盘。
    // 现在先读每个解节点的解数 getSize()[1]，再按块显式指定解编号（manualindices）逐块取，
    // 每块都校验列数；取不满就报错，绝不静默写出不完整的表。
    static final class SolUse {
        String tag;
        int n;          // 解数；<=0 表示该节点没有可用解
    }

    interface SliceSink {
        // solTag 解节点；from 起始解编号；nCols 本块解数；v[节点][表达式][解]
        void slice(String solTag, int from, int nCols, double[][][] v) throws Exception;
    }

    // 多次数据的模型：每个解节点配一个独立的 Solution 数据集，
    // 直接改 dset1 的 solution 属性在多研究/多步骤模型里不生效，会只剩第一步的解。
    static String datasetFor(Job j, String solTag) {
        String tag = "dset_sol_" + solTag;
        try {
            if (!Arrays.asList(j.model.result().dataset().tags()).contains(tag)) {
                j.model.result().dataset().create(tag, "Solution");
            }
            j.model.result().dataset(tag).set("solution", solTag);
            return tag;
        } catch (Exception e) {
            System.out.println("[driver] 警告: 解节点 " + solTag + " 建数据集失败（" + e.getMessage() + "），回退到 " + j.dataset);
            return j.dataset;
        }
    }

    static int chunkSize(Job j) {
        int c = 200;
        String s = j.p.getOrDefault("chunk", "").trim();
        if (!s.isEmpty()) {
            try { c = Integer.parseInt(s); } catch (Exception ignore) { }
        }
        return c < 1 ? 200 : (c > 5000 ? 5000 : c);
    }

    static List<SolUse> listSols(Job j) {
        List<SolUse> list = new ArrayList<>();
        for (String t : j.model.sol().tags()) {
            SolUse u = new SolUse();
            u.tag = t;
            u.n = 0;
            try {
                int[] sz = j.model.sol(t).getSize();
                if (sz != null && sz.length >= 2 && sz[1] > 0) u.n = sz[1];
            } catch (Exception ignore) { }
            list.add(u);
        }
        return list;
    }

    static String indexList(int from, int to) {
        StringBuilder sb = new StringBuilder();
        for (int k = from; k <= to; k++) {
            if (sb.length() > 0) sb.append(' ');
            sb.append(k);
        }
        return sb.toString();
    }

    static void pinChunk(Job j, String node, int from, int to) {
        try {
            j.model.result().numerical(node).set("innerinput", "manualindices");
            j.model.result().numerical(node).set("solnumindices", indexList(from, to));
        } catch (Exception e) {
            throw new IllegalStateException("按解编号取数失败（" + node + " ← 解 " + from + "…" + to + "）: " + e.getMessage());
        }
    }

    static void unpinChunk(Job j, String node) {
        try { j.model.result().numerical(node).set("innerinput", "all"); } catch (Exception ignore) { }
    }

    static double[][] realChunk(Job j, String node, int expect, String where) {
        double[][] a;
        try {
            a = j.model.result().numerical(node).getReal();
        } catch (Exception e) {
            throw new IllegalStateException(where + " 取数失败（节点 " + node + "）: " + e.getMessage());
        }
        int got = (a == null || a.length == 0) ? 0 : a[0].length;
        if (got != expect) {
            throw new IllegalStateException(where + " 取数不完整：要 " + expect + " 列，实得 " + got
                    + " 列（节点 " + node + "）。可能是解没存全，或 Java 堆不够（当前 max="
                    + (Runtime.getRuntime().maxMemory() >> 20) + "MB）；确认后加大 -Xmx 重试。");
        }
        return a;
    }

    static LinkedHashMap<String, int[]> walkSols(Job j, String[] nodes, SliceSink sink) throws Exception {
        LinkedHashMap<String, int[]> stat = new LinkedHashMap<>();
        int chunk = chunkSize(j);
        int totN = 0;
        for (SolUse u : j.sols) { if (u.n > 0) totN += u.n; }
        int doneN = 0;
        progress(0, totN, PROGRESS_LABEL);
        for (SolUse u : j.sols) {
            if (u.n <= 0) continue;
            String dset = datasetFor(j, u.tag);
            for (String nd : nodes) j.model.result().numerical(nd).set("data", dset);
            int got = 0;
            for (int from = 1; from <= u.n; from += chunk) {
                int to = Math.min(u.n, from + chunk - 1);
                int nCols = to - from + 1;
                for (String nd : nodes) pinChunk(j, nd, from, to);
                double[][][] v = new double[nodes.length][][];
                for (int q = 0; q < nodes.length; q++) {
                    v[q] = realChunk(j, nodes[q], nCols, "解节点 " + u.tag + " 第 " + from + "…" + to + " 个解");
                }
                sink.slice(u.tag, from, nCols, v);
                got += nCols;
                doneN += nCols;
                progress(doneN, totN, PROGRESS_LABEL);
            }
            for (String nd : nodes) unpinChunk(j, nd);
            stat.put(u.tag, new int[] { u.n, got });
        }
        progress(totN, totN, PROGRESS_LABEL);
        return stat;
    }

    static void logSols(LinkedHashMap<String, int[]> stat) {
        int tot = 0, cols = 0;
        for (Map.Entry<String, int[]> e : stat.entrySet()) {
            int[] v = e.getValue();
            System.out.println("[driver]   解节点 " + e.getKey() + ": 期望 " + v[0] + " 个解，取到 " + v[1] + " 列");
            tot += v[0];
            cols += v[1];
        }
        System.out.println("[driver]   合计 " + tot + " 个解，取到 " + cols + " 列");
    }

    static void requireNoLoss(Job j, int i, int nan) {
        if (nan <= 0) return;
        if ("1".equals(j.block(i, "allownan", "0").trim())) {
            System.out.println("[driver] 警告: 有 " + nan + " 个解算不出数（NaN/Inf），已按 Allownan=1 跳过");
            return;
        }
        throw new IllegalStateException("有 " + nan + " 个解算不出数（NaN/Inf），拒绝写出不完整的表；"
                + "若这些点本来无定义，可在该块加 Allownan=1。heap max="
                + (Runtime.getRuntime().maxMemory() >> 20) + "MB");
    }

    // 整行内容做键，替掉 O(n²) 的全表比较
    static final class RowKey {
        final double[] v;
        final int h;
        RowKey(double[] v) { this.v = v; this.h = Arrays.hashCode(v); }
        @Override public int hashCode() { return h; }
        @Override public boolean equals(Object o) {
            return (o instanceof RowKey) && Arrays.equals(v, ((RowKey) o).v);
        }
    }

    // 流式写 CSV：逐行落 .part，全部成功才改名；中途失败不留半截文件
    static final class CsvStream {
        final Path target, part;
        final BufferedWriter w;
        boolean nmFirst, committed;
        CsvStream(Path target, String[] cols) throws IOException {
            this.target = target;
            Files.createDirectories(target.getParent());
            this.part = target.resolveSibling(target.getFileName() + ".part");
            this.w = Files.newBufferedWriter(part, StandardCharsets.UTF_8);
            w.write(String.join(",", cols));
            w.newLine();
        }
        void row(double[] v) throws IOException {
            StringBuilder sb = new StringBuilder();
            for (int q = 0; q < v.length; q++) {
                if (q > 0) sb.append(',');
                if (q == 0 && nmFirst) {
                    // 6.4 的 c_const/ewfd.freq 直接给 nm；别的版本给 m，按量级兜一下
                    double nm = Math.abs(v[q]) < 1.0 ? v[q] * 1e9 : v[q];
                    sb.append(String.format(Locale.ROOT, "%.2f", nm));
                } else {
                    sb.append(String.format(Locale.ROOT, "%.6g", v[q]));
                }
            }
            w.write(sb.toString());
            w.newLine();
        }
        void commit() throws IOException {
            w.close();
            Files.move(part, target, StandardCopyOption.REPLACE_EXISTING);
            committed = true;
        }
        void abort() {
            if (committed) return;
            try { w.close(); } catch (Exception ignore) { }
            try { Files.deleteIfExists(part); } catch (Exception ignore) { }
        }
    }

    static boolean nmFirst(String[] cols, String[] expr) {
        return cols.length > 0 && expr.length > 0
                && cols[0].endsWith("_nm") && expr[0].trim().startsWith("c_const/");
    }

    // ---------- global / spectrum ----------
    // expr / cols：| 分隔；扫描变量自动前置若干列
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

        String node = "gev_export_" + i;
        if (!Arrays.asList(j.model.result().numerical().tags()).contains(node)) {
            j.model.result().numerical().create(node, "EvalGlobal");
        }
        j.model.result().numerical(node).set("data", j.dataset);
        j.model.result().numerical(node).set("expr", expr);
        j.model.result().numerical(node).set("descr", cols);

        Path target = csvTarget(j, i, name);
        CsvStream out = new CsvStream(target, cols);
        out.nmFirst = nmFirst(cols, expr);
        Set<RowKey> seen = new HashSet<>();
        int[] st = new int[3];              // 0 行数, 1 NaN 个数, 2 重复行数
        try {
            LinkedHashMap<String, int[]> stat = walkSols(j, new String[] { node }, (tag, from, nCols, v) -> {
                double[][] a = v[0];
                for (int c = 0; c < nCols; c++) {
                    double[] row = new double[expr.length];
                    boolean ok = true;
                    for (int q = 0; q < expr.length; q++) {
                        double val = a[q][c];
                        row[q] = val;
                        if (Double.isNaN(val) || Double.isInfinite(val)) ok = false;
                    }
                    if (!ok) { st[1]++; continue; }
                    if (!seen.add(new RowKey(row))) { st[2]++; continue; }
                    out.row(row);
                    st[0]++;
                }
            });
            logSols(stat);
            if (st[0] == 0) throw new IllegalStateException("没有取到任何解（检查解节点与表达式）");
            requireNoLoss(j, i, st[1]);
            out.commit();
        } finally {
            out.abort();
        }
        System.out.println("[driver] 写出 " + target + "（" + st[0] + " 行 × " + cols.length + " 列"
                + (st[2] > 0 ? "，重复解已合并 " + st[2] + " 行" : "") + "）");
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
    // 一次出四张：三维默认视图一张（三个正交切片），xy / xz / zy 三个二维正投影各一张。
    // expr（默认 ewfd.normE）、solnum（默认 1）、at（切面位置，默认 auto=几何中心）、
    // plane（at 作用在哪个面上，兼容旧配方，默认 xy）、edges（on|off，默认 off）、
    // width/height（像素，默认 800x600）、title（图题后缀）
    static void exportImage(Job j, int i) throws Exception {
        String name = j.block(i, "name", "image");
        String expr = j.block(i, "expr", "ewfd.normE").trim();
        String solnum = j.block(i, "solnum", "1").trim();
        String at = j.block(i, "at", "auto").trim();
        String edges = j.block(i, "edges", "off").trim();
        String title = j.block(i, "title", "").trim();

        double[] bb = bbox6(j);
        double zc = (bb[4] + bb[5]) / 2, yc = (bb[2] + bb[3]) / 2, xc = (bb[0] + bb[1]) / 2;
        if (!at.isEmpty() && !at.equalsIgnoreCase("auto")) {
            // 兼容旧配方：at 只挪动三维视图里的主切片，坐标用模型的长度单位
            String plane = j.block(i, "plane", "xy").trim();
            double off = Double.parseDouble(at);
            if ("xy".equals(plane)) zc = off;
            else if ("zx".equals(plane)) yc = off;
            else xc = off;
            System.out.println("[driver] 三维主切片 " + plane + " 位置 " + off);
        }

        // 1) 三维默认视图：三个互相垂直的切片，一次看全
        String tag3 = "pg_img3_" + i;
        if (!hasResult(j, tag3)) j.model.result().create(tag3, "PlotGroup3D");
        j.model.result(tag3).set("data", j.dataset);
        trySet(j.model.result(tag3), "solnum", solnum);
        String[][] cuts = {
                { "sli1", "xy", "quickz", Double.toString(zc) },
                { "sli2", "zx", "quicky", Double.toString(yc) },
                { "sli3", "yz", "quickx", Double.toString(xc) } };
        for (String[] c : cuts) {
            if (!hasResultFeature(j, tag3, c[0])) j.model.result(tag3).create(c[0], "Slice");
            j.model.result(tag3).feature(c[0]).set("quickplane", c[1]);
            trySet(j.model.result(tag3).feature(c[0]), c[2], c[3]);
            j.model.result(tag3).feature(c[0]).set("expr", expr);
        }
        decorate(j.model.result(tag3), edges, "三维视图（三正交切片）", title, "");
        j.model.result(tag3).run();
        // 三个切片取对数范围不同会各画一条色标；统一到共同范围，只留一条
        double[] rng = commonRange(j, tag3, cuts.length);
        if (rng != null) {
            for (int d = 0; d < cuts.length; d++) {
                Object sl = j.model.result(tag3).feature(cuts[d][0]);
                trySet(sl, "rangecoloractive", "on");
                trySet(sl, "rangecolormin", Double.toString(rng[0]));
                trySet(sl, "rangecolormax", Double.toString(rng[1]));
                trySet(sl, "colorlegend", d == 0 ? "on" : "off");
            }
            j.model.result(tag3).run();
        }
        // 三维组的自动标题会把三个 Slice 的标题拼三遍（「切面: … 切面: … 切面: …」），
        // 改成从第一个 Slice 的自动标题里取一次量名
        String q3 = tryGetString(j.model.result(tag3).feature(cuts[0][0]), "title").trim();
        int colon = q3.indexOf(':');
        if (colon < 0) colon = q3.indexOf('：');
        if (colon >= 0) q3 = q3.substring(colon + 1).trim();
        String t3 = title == null ? "" : title.trim();
        if (t3.isEmpty()) t3 = q3.isEmpty() ? "三维视图（三正交切片）" : "三维视图（三正交切片） · " + q3;
        applyTitle(j.model.result(tag3), t3, t3, "");
        Path png3 = j.outdir.resolve(j.outname + "_" + name + "_3d.png");
        exportPng(j, i, tag3, png3);
        System.out.println("[driver] 写出 " + png3);

        // 2) 三个二维正投影：CutPlane 数据集 + 2D 绘图组，正对着看
        String v2 = "";   // 第一次循环里按绘图组挑现成的二维视图
        int pxW = Integer.parseInt(j.block(i, "width", "1200").trim());
        int pxH = Integer.parseInt(j.block(i, "height", "0").trim());   // 0 = 按切面真实长宽比算高度
        // 真实比例出图：不做任何拉伸（二维视图保持 1:1）
        String[][] planes = {
                { "xy", "_xy", "XY" }, { "zx", "_xz", "XZ" }, { "yz", "_zy", "ZY" } };
        for (String[] pl : planes) {
            String plane = pl[0], suffix = pl[1], caption = pl[2];
            double pos = "xy".equals(plane) ? zc : ("zx".equals(plane) ? yc : xc);
            String dtag = "dsp2d_" + i + "_" + plane;
            if (!hasDataset(j, dtag)) j.model.result().dataset().create(dtag, "CutPlane");
            j.model.result().dataset(dtag).set("data", j.dataset);
            j.model.result().dataset(dtag).set("quickplane", plane);
            trySet(j.model.result().dataset(dtag), offsetKey(plane), Double.toString(pos));

            String pg = "pg2d_" + i + "_" + plane;
            if (!hasResult(j, pg)) j.model.result().create(pg, "PlotGroup2D");
            j.model.result(pg).set("data", dtag);
            trySet(j.model.result(pg), "solnum", solnum);
            if (!hasResultFeature(j, pg, "surf1")) j.model.result(pg).create("surf1", "Surface");
            j.model.result(pg).feature("surf1").set("expr", expr);
            if (v2.isEmpty()) v2 = pick2dView(j, pg);
            if (!v2.isEmpty()) {
                trySet(j.model.result(pg), "view", v2);
                setViewLimits(j, v2, plane, bb);
            }
            decorate(j.model.result(pg), edges, caption + " 切面", title, "");
            j.model.result(pg).run();
            int[] px = canvasSize(pxW, pxH, plane, bb);
            applyTitle(j.model.result(pg), caption + " 切面", title, "");
            Path png2 = j.outdir.resolve(j.outname + "_" + name + suffix + ".png");
            exportPng(j, i, pg, png2, px[0], px[1]);
            System.out.println("[driver] 写出 " + png2);
        }
    }

    // 挑一个现成的二维结果视图：从绘图组 view 的合法值里拿（auto/new 之外的那个）
    static String pick2dView(Job j, String group) {
        try {
            Object grp = j.model.result(group);
            String[] vals = (String[]) grp.getClass()
                    .getMethod("getAllowedPropertyValues", String.class).invoke(grp, "view");
            for (String v : vals) {
                String s = v == null ? "" : v.trim();
                if (s.isEmpty() || s.equalsIgnoreCase("auto") || s.equalsIgnoreCase("new")) continue;
                return s;
            }
        } catch (Exception ignore) { }
        return "";
    }

    // 二维视图的坐标范围改成"正好包住这个切面"；二维坐标里 plane 名的第一个字母是横轴
    static void setViewLimits(Job j, String view, String plane, double[] bb) {
        double x0, x1, y0, y1;
        if ("xy".equals(plane)) { x0 = bb[0]; x1 = bb[1]; y0 = bb[2]; y1 = bb[3]; }
        else if ("zx".equals(plane)) { x0 = bb[4]; x1 = bb[5]; y0 = bb[0]; y1 = bb[1]; }
        else { x0 = bb[2]; x1 = bb[3]; y0 = bb[4]; y1 = bb[5]; }
        double padx = (x1 - x0) * 0.02, pady = (y1 - y0) * 0.02;
        Object ax;
        try { ax = j.model.view(view).axis(); } catch (Exception e) { return; }
        trySet(ax, "viewscaletype", "manual");   // manual 才认下面的轴范围；none 会自动缩
        trySet(ax, "xscale", "1");               // 先归零，否则上一张图的拉伸会把轴撑开
        trySet(ax, "yscale", "1");
        trySet(ax, "xmin", Double.toString(x0 - padx));
        trySet(ax, "xmax", Double.toString(x1 + padx));
        trySet(ax, "ymin", Double.toString(y0 - pady));
        trySet(ax, "ymax", Double.toString(y1 + pady));
    }

    // 画布尺寸：height=0 时按切面真实长宽比算 —— 短边至少 500px，长边相应放大，
    // 既保持真实比例，又不至于把面板压成一条线
    static int[] canvasSize(int w, int h, String plane, double[] bb) {
        if (h > 0) return new int[] { w, h };
        double spanX, spanY;
        if ("xy".equals(plane)) { spanX = bb[1] - bb[0]; spanY = bb[3] - bb[2]; }
        else if ("zx".equals(plane)) { spanX = bb[5] - bb[4]; spanY = bb[1] - bb[0]; }
        else { spanX = bb[3] - bb[2]; spanY = bb[5] - bb[4]; }
        if (spanX <= 0 || spanY <= 0) return new int[] { w, 900 };
        double aspect = spanX / spanY;                 // 横向 / 纵向
        int shortSide = 500, longSide = 1200, maxSide = 4096;
        int px, py;
        if (aspect >= 1) {
            py = shortSide;
            px = (int) Math.round(shortSide * aspect);
            if (px < longSide) { px = longSide; py = (int) Math.round(longSide / aspect); }
        } else {
            px = shortSide;
            py = (int) Math.round(shortSide / aspect);
            if (py < longSide) { py = longSide; px = (int) Math.round(longSide * aspect); }
        }
        int big = Math.max(px, py);
        if (big > maxSide) {   // COMSOL 单边上限 4096 px
            double k = (double) maxSide / big;
            px = Math.max(80, (int) Math.round(px * k));
            py = Math.max(80, (int) Math.round(py * k));
        }
        return new int[] { px, py };
    }

    static String axisSpan(String plane, double[] bb, boolean horiz) {
        double a, b;
        if ("xy".equals(plane)) { a = horiz ? bb[0] : bb[2]; b = horiz ? bb[1] : bb[3]; }
        else if ("zx".equals(plane)) { a = horiz ? bb[4] : bb[0]; b = horiz ? bb[5] : bb[1]; }
        else { a = horiz ? bb[2] : bb[4]; b = horiz ? bb[3] : bb[5]; }
        return String.format(Locale.ROOT, "%.4g … %.4g", a, b);
    }

    // 多个绘图特征共用一条色标：取各自实际范围的并集
    static double[] commonRange(Job j, String group, int n) {
        double lo = Double.POSITIVE_INFINITY, hi = Double.NEGATIVE_INFINITY;
        try {
            for (int d = 1; d <= n; d++) {
                String s = tryGetString(j.model.result(group).feature("sli" + d), "rangeactualminmax");
                if (s == null || s.indexOf(',') < 0) continue;
                double a = Double.parseDouble(s.substring(0, s.indexOf(',')).trim());
                double b = Double.parseDouble(s.substring(s.indexOf(',') + 1).trim());
                lo = Math.min(lo, a);
                hi = Math.max(hi, b);
            }
        } catch (Exception ignore) { }
        if (lo == Double.POSITIVE_INFINITY || hi == Double.NEGATIVE_INFINITY || hi <= lo) return null;
        return new double[] { lo, hi };
    }

    // 图题、色标、坐标轴打开（导出时还要在 Image 节点上开 optionsNd）
    static void decorate(Object rf, String edges, String prefix, String title, String note) {
        trySet(rf, "edges", edges);
        trySet(rf, "legendactive", "on");
        trySet(rf, "axisactive", "on");
    }

    // 图题必须在 run() 之后拼：run 之前 getString("title") 是空串，run 之后才是「电场模 (V/m)」这种自动名
    static void applyTitle(Object rf, String prefix, String title, String note) {
        String t = title == null ? "" : title.trim();
        if (t.isEmpty()) {
            String auto = tryGetString(rf, "title");
            if (auto != null) auto = auto.trim();
            if (auto.isEmpty()) t = prefix;
            else t = prefix.isEmpty() ? auto : prefix + " · " + auto;
        }
        if (note != null && !note.isEmpty()) t = t + "（" + note + "）";
        trySet(rf, "titletype", "manual");
        trySet(rf, "title", t);
    }

    static String tryGetString(Object node, String key) {
        try {
            Object v = node.getClass().getMethod("getString", String.class).invoke(node, key);
            return v == null ? "" : v.toString();
        } catch (Exception e) {
            return "";
        }
    }

    static void trySet(Object node, String key, String val) {
        try {
            node.getClass().getMethod("set", String.class, String.class).invoke(node, key, val);
        } catch (Exception ignore) { }
    }

    static boolean hasResult(Job j, String tag) {
        try {
            return Arrays.asList(j.model.result().tags()).contains(tag);
        } catch (Exception e) {
            return false;
        }
    }

    static boolean hasResultFeature(Job j, String group, String tag) {
        try {
            return Arrays.asList(j.model.result(group).feature().tags()).contains(tag);
        } catch (Exception e) {
            return false;
        }
    }

    static boolean hasDataset(Job j, String tag) {
        try {
            return Arrays.asList(j.model.result().dataset().tags()).contains(tag);
        } catch (Exception e) {
            return false;
        }
    }

    // 几何包围盒 [x0,x1,y0,y1,z0,z1]，单位与几何一致（切面位置也用这个单位）
    static double[] bbox6(Job j) {
        try {
            for (String c : j.model.component().tags()) {
                for (String g : j.model.component(c).geom().tags()) {
                    double[] bb = j.model.component(c).geom(g).getBoundingBox();
                    if (bb.length >= 6) return new double[] { bb[0], bb[1], bb[2], bb[3], bb[4], bb[5] };
                }
            }
        } catch (Exception ignore) { }
        System.out.println("[driver] 警告：取不到几何包围盒，切片位置用 0");
        return new double[] { 0, 0, 0, 0, 0, 0 };
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
        List<SolUse> sols = j.sols.isEmpty() ? listSols(j) : j.sols;
        boolean multiSol = sols.size() > 1;
        int solIdx = 0;
        for (SolUse su : sols) {
            if (su.n <= 0) continue;
            String solTag = su.tag;
            solIdx++;
            int nMode = Math.min(su.n, maxModes);
            String dset = "dset_eig_" + i + "_" + solTag;
            if (!Arrays.asList(j.model.result().dataset().tags()).contains(dset)) {
                j.model.result().dataset().create(dset, "Solution");
            }
            j.model.result().dataset(dset).set("solution", solTag);
            j.model.result(tag).set("data", dset);
            for (int k = 1; k <= nMode; k++) {
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
        double[] bb = bbox6(j);   // 与几何同单位，切面偏移也用这个单位
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
                if (plane.equals("xy")) pos = Double.toString((bb[4] + bb[5]) / 2);
                else if (plane.equals("zx")) pos = Double.toString((bb[2] + bb[3]) / 2);
                else pos = Double.toString((bb[0] + bb[1]) / 2);
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
            decorate(j.model.result(pg), j.block(i, "edges", "off").trim(),
                    plane.toUpperCase(Locale.ROOT) + " 切面", j.block(i, "title", "").trim(), "");
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
        List<double[]> found = evalAll(j, i, node, expr.length);
        if (found.isEmpty()) throw new IllegalStateException("积分没有取到任何值（检查实体编号与表达式）");
        double[][] data = new double[expr.length][found.size()];
        for (int c = 0; c < found.size(); c++)
            for (int q = 0; q < expr.length; q++) data[q][c] = found.get(c)[q];
        Path target = csvTarget(j, i, name);
        writeCsv(target, data, expr, cols);
        System.out.println("[driver] 写出 " + target);
    }


    // ---------- bigtable：通用原始大表（全局参数 + 谱线 + 各域吸收） ----------
    static void exportBigTable(Job j, int i) throws Exception {
        String name = j.block(i, "name", "bigtable");
        String domSpec = j.block(i, "absdomains", "auto").trim();
        String absExpr = j.block(i, "absexpr", "ewfd.Qh").trim();
        String paramSpec = j.block(i, "params", "all").trim().toLowerCase(Locale.ROOT);

        // 1) 全局参数表达式
        List<String> pExps = new ArrayList<>();
        List<String> pNames = new ArrayList<>();
        if (!paramSpec.equals("none")) {
            for (String v : j.model.param().varnames()) {
                if (paramSpec.equals("all") || Arrays.asList(split(paramSpec)).contains(v.toLowerCase(Locale.ROOT))) {
                    pExps.add(v); pNames.add(v + "_val");
                }
            }
        }

        String[] specExpr = { "c_const/ewfd.freq", "ewfd.freq/1e12", "abs(ewfd.S21)^2", "abs(ewfd.S11)^2",
                "ewfd.Ttotal", "ewfd.Rtotal", "arg(ewfd.S21)", "1-ewfd.Ttotal-ewfd.Rtotal", "ewfd.Pin" };
        String[] specCols = { "lambda_nm", "freq_THz", "T00", "R00", "T_total", "R_total",
                "phase_S21_rad", "A_1-T-R", "Pin_W" };

        // 2) 吸收域：编号 + 英文名（auto = 材料名含 ITO 的域，按 z 中心自动排序）
        int[] domIds;
        String[] domNames;
        if (domSpec.equalsIgnoreCase("auto")) {
            List<Integer> cand = new ArrayList<>();
            for (String mt : j.model.component("comp1").material().tags()) {
                String label = j.model.component("comp1").material(mt).label();
                if (label == null || !label.toLowerCase(Locale.ROOT).contains("ito")) continue;
                for (int e : j.model.component("comp1").material(mt).selection().entities(3))
                    if (!cand.contains(e)) cand.add(e);
            }
            if (cand.isEmpty()) throw new IllegalStateException("没有找到材料名含 ITO 的域（可在 AbsDomains 里显式写编号）");
            double[] zc = new double[cand.size()];
            for (int z = 0; z < cand.size(); z++) zc[z] = domainZCenter(j, cand.get(z));
            Integer[] order = new Integer[cand.size()];
            for (int z = 0; z < order.length; z++) order[z] = z;
            final double[] zref = zc;
            java.util.Arrays.sort(order, (a, b) -> Double.compare(zref[a], zref[b]));
            domIds = new int[cand.size()];
            domNames = new String[cand.size()];
            for (int z = 0; z < order.length; z++) {
                domIds[z] = cand.get(order[z]);
                domNames[z] = layerName(z, order.length);
            }
        } else if (domSpec.isEmpty() || domSpec.equalsIgnoreCase("none")) {
            domIds = new int[0]; domNames = new String[0];
        } else {
            List<Integer> ids = new ArrayList<>();
            List<String> nms = new ArrayList<>();
            for (String s : domSpec.split(",")) {
                String x = s.trim();
                if (x.isEmpty()) continue;
                int id; String nm;
                int c = x.indexOf(':');
                if (c > 0) { id = Integer.parseInt(x.substring(0, c).trim()); nm = x.substring(c + 1).trim(); }
                else { id = Integer.parseInt(x); nm = "d" + id; }
                ids.add(id); nms.add(nm);
            }
            domIds = new int[ids.size()]; domNames = new String[ids.size()];
            for (int z = 0; z < ids.size(); z++) { domIds[z] = ids.get(z); domNames[z] = nms.get(z); }
        }

        // 3) 建节点
        String gNode = "bt_g_" + i;
        if (!Arrays.asList(j.model.result().numerical().tags()).contains(gNode))
            j.model.result().numerical().create(gNode, "EvalGlobal");
        j.model.result().numerical(gNode).set("data", j.dataset);
        List<String> allExps = new ArrayList<>(pExps);
        java.util.Collections.addAll(allExps, specExpr);
        j.model.result().numerical(gNode).set("expr", allExps.toArray(new String[0]));

        List<String> intNodes = new ArrayList<>();
        for (int d : domIds) {
            String n = "bt_iv_" + i + "_" + d;
            if (!Arrays.asList(j.model.result().numerical().tags()).contains(n))
                j.model.result().numerical().create(n, "IntVolume");
            j.model.result().numerical(n).set("data", j.dataset);
            j.model.result().numerical(n).set("expr", new String[] { absExpr });
            try { j.model.result().numerical(n).selection().set(new int[] { d }); }
            catch (Exception e) { throw new IllegalStateException("吸收域编号不存在: " + d + " — " + e.getMessage()); }
            intNodes.add(n);
        }

        // 4) 逐解取数（按块显式指定解编号，逐块校验列数；逐行流式写盘）
        int nP = pExps.size();
        int nDom = domIds.length;
        String[] nodes = new String[1 + nDom];
        nodes[0] = gNode;
        for (int z = 0; z < nDom; z++) nodes[z + 1] = intNodes.get(z);

        // 5) 列名（全 ASCII）
        List<String> cols = new ArrayList<>(pNames);
        java.util.Collections.addAll(cols, specCols);
        for (String nm : domNames) { cols.add("Qrh_ITO_" + nm + "_W"); cols.add("A_ITO_" + nm + "_pct"); }
        cols.add("Qrh_ITO_total_W"); cols.add("A_ITO_total_pct");

        Path target = csvTarget(j, i, name);
        CsvStream out = new CsvStream(target, cols.toArray(new String[0]));
        out.nmFirst = nmFirst(cols.toArray(new String[0]), specExpr);
        Set<RowKey> seen = new HashSet<>();
        int[] st = new int[3];              // 0 行数, 1 NaN 个数, 2 重复行数
        int base = nP + specExpr.length;
        try {
            LinkedHashMap<String, int[]> stat = walkSols(j, nodes, (tag, from, nCols, v) -> {
                double[][] a = v[0];
                for (int c = 0; c < nCols; c++) {
                    double[] row = new double[cols.size()];
                    boolean ok = true;
                    for (int q = 0; q < a.length; q++) {
                        double val = a[q][c];
                        if (Double.isNaN(val) || Double.isInfinite(val)) { ok = false; break; }
                        row[q] = val;
                    }
                    if (!ok) { st[1]++; continue; }
                    double pin = row[nP + 8];
                    if (pin == 0) pin = 1.0;
                    row[nP + 8] = pin;
                    double sumQ = 0;
                    for (int z = 0; z < nDom; z++) {
                        double q = v[z + 1][0][c];
                        if (Double.isNaN(q) || Double.isInfinite(q)) { ok = false; break; }
                        row[base + z * 2] = q;
                        row[base + z * 2 + 1] = 100.0 * q / pin;
                        sumQ += q;
                    }
                    if (!ok) { st[1]++; continue; }
                    row[base + nDom * 2] = sumQ;
                    row[base + nDom * 2 + 1] = 100.0 * sumQ / pin;
                    if (!seen.add(new RowKey(row))) { st[2]++; continue; }
                    out.row(row);
                    st[0]++;
                }
            });
            logSols(stat);
            if (st[0] == 0) throw new IllegalStateException("大表没有取到任何数据（检查解节点与研究设置）");
            requireNoLoss(j, i, st[1]);
            out.commit();
        } finally {
            out.abort();
        }
        System.out.println("[driver] 写出 " + target + "（" + st[0] + " 行 × " + cols.size() + " 列"
                + (st[2] > 0 ? "，重复解已合并 " + st[2] + " 行" : "") + "）");
    }

    // 按 z 位置给吸收域起英文名：1 个 ito；2 个 lower/upper；3 个 lower/hole/upper
    static String layerName(int idx, int n) {
        if (n <= 1) return "ito";
        if (n == 2) return idx == 0 ? "lower" : "upper";
        if (idx == 0) return "lower";
        if (idx == n - 1) return "upper";
        return "hole";
    }

    // 域的 z 中心（米）；取当前数据集第 1 个解
    static double domainZCenter(Job j, int dom) throws Exception {
        String tag = "bt_zc_" + dom;
        if (!Arrays.asList(j.model.result().numerical().tags()).contains(tag))
            j.model.result().numerical().create(tag, "IntVolume");
        j.model.result().numerical(tag).set("data", j.dataset);
        j.model.result().numerical(tag).set("expr", new String[] { "1", "z" });
        j.model.result().numerical(tag).selection().set(new int[] { dom });
        double[][] r = j.model.result().numerical(tag).getReal();
        double v = r[0][0];
        if (v == 0) throw new IllegalStateException("吸收域 " + dom + " 体积为 0");
        return r[1][0] / v;
    }

    // ---------- modes：每个模态一行数值 ----------
    static void exportModes(Job j, int i) throws Exception {
        String name = j.block(i, "name", "modes");
        String[] exprIn = j.blockArr(i, "expr");
        String[] colsIn = j.blockArr(i, "cols");
        if (exprIn.length == 0) { exprIn = new String[] { "ewfd.freq" }; colsIn = new String[] { "freq" }; }
        if (colsIn.length != exprIn.length) throw new IllegalStateException("expr/cols 数量不匹配");
        final String[] expr = exprIn;
        final String[] cols = colsIn;
        int maxModes = Integer.parseInt(j.block(i, "maxmodes", "50").trim());
        String node = "gmod_" + i;
        if (!Arrays.asList(j.model.result().numerical().tags()).contains(node)) {
            j.model.result().numerical().create(node, "EvalGlobal");
        }
        j.model.result().numerical(node).set("data", j.dataset);
        j.model.result().numerical(node).set("expr", expr);
        j.model.result().numerical(node).set("descr", cols);
        // 逐解取数（按块显式指定解编号），按表达式去重后连续编号
        List<double[]> rows = new ArrayList<>();
        Set<RowKey> seen = new HashSet<>();
        int[] st = new int[3];
        LinkedHashMap<String, int[]> stat = walkSols(j, new String[] { node }, (tag, from, nCols, v) -> {
            double[][] a = v[0];
            for (int c = 0; c < nCols; c++) {
                double[] row = new double[expr.length + 1];
                boolean ok = true;
                for (int q = 0; q < expr.length; q++) {
                    double val = a[q][c];
                    if (Double.isNaN(val) || Double.isInfinite(val)) { ok = false; break; }
                    row[q + 1] = val;
                }
                if (!ok) { st[1]++; continue; }
                double[] key = new double[expr.length];
                System.arraycopy(row, 1, key, 0, expr.length);
                if (!seen.add(new RowKey(key))) { st[2]++; continue; }
                row[0] = rows.size() + 1;
                rows.add(row);
                st[0]++;
            }
        });
        logSols(stat);
        if (rows.isEmpty()) throw new IllegalStateException("没有取到任何模态（检查解节点与表达式）");
        requireNoLoss(j, i, st[1]);
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

    // 遍历所有解节点与解编号取数，按行去重（积分共用）
    static List<double[]> evalAll(Job j, int i, String node, int nExpr) throws Exception {
        List<double[]> found = new ArrayList<>();
        Set<RowKey> seen = new HashSet<>();
        int[] st = new int[3];
        LinkedHashMap<String, int[]> stat = walkSols(j, new String[] { node }, (tag, from, nCols, v) -> {
            double[][] a = v[0];
            for (int c = 0; c < nCols; c++) {
                double[] row = new double[nExpr];
                boolean ok = true;
                for (int q = 0; q < nExpr; q++) {
                    double val = a[q][c];
                    if (Double.isNaN(val) || Double.isInfinite(val)) { ok = false; break; }
                    row[q] = val;
                }
                if (!ok) { st[1]++; continue; }
                if (!seen.add(new RowKey(row))) { st[2]++; continue; }
                found.add(row);
                st[0]++;
            }
        });
        logSols(stat);
        requireNoLoss(j, i, st[1]);
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
        exportPng(j, i, plotGroup, target, 0, 0);
    }

    static void exportPng(Job j, int i, String plotGroup, Path target, int w, int h) throws Exception {
        String tag = "img_" + i + "_" + Math.abs((plotGroup + target.toString()).hashCode() % 1000000);
        if (!Arrays.asList(j.model.result().export().tags()).contains(tag)) {
            j.model.result().export().create(tag, "Image");
        }
        j.model.result().export(tag).set("plotgroup", plotGroup);
        j.model.result().export(tag).set("imagetype", "png");
        j.model.result().export(tag).set("size", "manualweb");
        j.model.result().export(tag).set("unit", "px");
        j.model.result().export(tag).set("width", w > 0 ? Integer.toString(w) : j.block(i, "width", "1200").trim());
        j.model.result().export(tag).set("height", h > 0 ? Integer.toString(h) : j.block(i, "height", "900").trim());
        // 图题/色标/坐标轴的总闸在导出节点上；绘图组里那些开关不参与导出渲染
        Object ex = j.model.result().export(tag);
        trySet(ex, "options1d", "on");
        trySet(ex, "options2d", "on");
        trySet(ex, "options3d", "on");
        trySet(ex, "title1d", "on");
        trySet(ex, "title2d", "on");
        trySet(ex, "title3d", "on");
        trySet(ex, "legend1d", "on");
        trySet(ex, "legend2d", "on");
        trySet(ex, "legend3d", "on");
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
