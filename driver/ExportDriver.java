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
        Path jobDir, outdir, modelsDir, tmpdir;
        String outname, dataset, study, component = "";
        int blocks, currentBlock, skipped;
        final Map<Integer,Integer> blockFiles = new HashMap<>();
        String runtime = "", loadedModel = "";
        final Set<Path> expected = new LinkedHashSet<>();
        final Map<Path,String> artifacts = new LinkedHashMap<>();
        final List<String> details = new ArrayList<>();
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

    // 跑的是哪份 class：路径 + 修改时间。远程更新若只换了 .ps1 没换 .class，这里一眼看出来。
    static String classStamp() {
        try {
            java.security.CodeSource cs = ExportDriver.class.getProtectionDomain().getCodeSource();
            if (cs == null || cs.getLocation() == null) return "class=?";
            java.nio.file.Path p = java.nio.file.Paths.get(cs.getLocation().toURI())
                    .resolve("ExportDriver.class");
            String ts = java.nio.file.Files.getLastModifiedTime(p).toString();
            return "class=" + p + " (" + ts + ")";
        } catch (Exception e) {
            return "class=?(" + e.getClass().getSimpleName() + ")";
        }
    }

    // 把 COMSOL 的 FlException 打印成一行也看得懂：多行合并、保留「- 标记: xxx」这类关键行
    static String errText(Throwable e) {
        Throwable root = e;
        while (root.getCause() != null && root.getCause() != root) root = root.getCause();
        String msg = root.getMessage() == null ? "" : root.getMessage().trim();
        msg = msg.replace("\r", "").replace("\n", " / ");
        while (msg.contains("  ")) msg = msg.replace("  ", " ");
        StringBuilder sb = new StringBuilder();
        if (e != root && e.getMessage() != null) sb.append(e.getMessage().replace("\n", " / ")).append(" · ");
        sb.append(root.getClass().getSimpleName());
        if (!msg.isEmpty()) sb.append(": ").append(msg);
        StackTraceElement[] st = root.getStackTrace();
        if (st != null) {
            for (int k = 0; k < st.length && k < 4; k++) {
                StackTraceElement f = st[k];
                if (f.getClassName().startsWith("com.comsol")) continue;   // 只留自己的帧
                sb.append(" @ ").append(f.getMethodName()).append("(").append(f.getFileName()).append(":")
                        .append(f.getLineNumber()).append(")");
            }
        }
        return sb.toString();
    }

    static String stackOf(Throwable t) {
        java.io.StringWriter sw = new java.io.StringWriter();
        t.printStackTrace(new java.io.PrintWriter(sw));
        return sw.toString();
    }

    // 驱动版本：远程日志里没有这行就说明跑的是旧 class（更新没覆盖到 driver 目录）
    static final String DRIVER_VERSION = "v1.9.0";

    static int progressBlock, progressBlocks, progressTotal, progressDone;
    static boolean progressImages;
    static final class JobFailure extends RuntimeException {
        final int code;
        JobFailure(int code, String message) { super(message); this.code = code; }
    }
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
        progressTotal = total;
        progressDone = done;
        if (PROGRESS_FILE == null) return;
        String s = "done=" + done + "\ntotal=" + total + "\nlabel=" + label
                + "\nunit=" + (progressImages ? "files" : "solutions") + "\nblock=" + progressBlock + "\nblocks=" + progressBlocks + "\nts=" + System.currentTimeMillis() + "\n";
        try {
            Path tmp = PROGRESS_FILE.resolveSibling("progress.tmp");
            Files.write(tmp, s.getBytes(StandardCharsets.UTF_8));
            publish(tmp, PROGRESS_FILE);
        } catch (Exception ignore) { }
    }

    public static void main(String[] args) {
        if (args.length == 1 && "--check-runtime".equals(args[0])) {
            try {
                ModelUtil.class.getMethod("loadCopy", String.class, String.class);
                com.comsol.model.SolverSequence.class.getMethod("study");
                com.comsol.model.Study.class.getMethod("getSolverSequences", String.class);
                com.comsol.model.NumericalFeature.class.getMethod("getReal");
                System.out.println(DRIVER_VERSION + " Java " + System.getProperty("java.version"));
                return;
            } catch (ReflectiveOperationException | LinkageError e) {
                System.err.println("驱动与所选 COMSOL 安装不兼容：" + e);
                System.exit(2);
            }
        }
        if (args.length != 1) {
            System.err.println("usage: ExportDriver <job.properties>");
            System.exit(2);
        }
        Job j = new Job();
        Path spec = Paths.get(args[0]).toAbsolutePath();
        j.jobDir = spec.getParent();
        LOG_FILE = j.jobDir.resolve("driver.self.log");
        PROGRESS_FILE = j.jobDir.resolve("progress.txt");
        int code = 0;
        String error = "";
        try {
            j.p = readSpec(spec);
            Files.writeString(j.jobDir.resolve("started"), "pid=" + ProcessHandle.current().pid());
            log("[driver] 启动 驱动版本=" + DRIVER_VERSION + " " + classStamp());
            execute(j);
        } catch (Throwable e) {
            code = e instanceof JobFailure ? ((JobFailure)e).code : 4;
            error = errText(e);
            log("[driver] " + error);
            log(stackOf(e));
            System.err.println(error);
        } finally {
            try { ModelUtil.clear(); } catch (Throwable ignored) { }
            if (j.tmpdir != null) {
                try { deleteTree(j.tmpdir); } catch (IOException e) { String note = "临时目录清理失败 " + j.tmpdir + " " + e; j.details.add(note); log(note); }
            }
        }
        try {
            if (j.outdir != null) writeManifest(j, code, error);
            if (code == 0) {
                Files.deleteIfExists(j.jobDir.resolve("exporting"));
                Files.writeString(j.jobDir.resolve("exported"), "ok");
                log("[driver] 全部完成");
            }
        } catch (Exception e) {
            code = 4;
            System.err.println("写出交接清单或完成标记失败：" + e);
        }
        try { Files.writeString(j.jobDir.resolve("exit"), Integer.toString(code)); }
        catch (IOException e) { System.err.println(e); }
        System.exit(code);
    }

    static void execute(Job j) throws Exception {
        String source = j.p.getOrDefault("model", "");
        j.outname = j.p.get("outname");
        j.blocks = Integer.parseInt(j.p.getOrDefault("blocks", "0"));
        if (source.isEmpty() || j.outname == null || j.blocks < 1)
            throw new JobFailure(2, "作业缺少 model、outname 或导出块");
        Path input = Paths.get(source).toAbsolutePath();
        Path root = Paths.get(j.p.get("outdir")).toAbsolutePath();
        j.outdir = j.p.containsKey("resultdir") ? Paths.get(j.p.get("resultdir")).toAbsolutePath().normalize() : root.resolve(modelBase(input));
        Files.createDirectories(j.outdir);
        j.modelsDir = Paths.get(j.p.getOrDefault("modelsdir", root.getParent().resolve("models").toString()));
        Path solved = j.p.containsKey("solvedfile") ? Paths.get(j.p.get("solvedfile"))
                : j.modelsDir.resolve("solved").resolve(j.outname + ".mph");
        if (!Files.isRegularFile(solved) && Files.isRegularFile(j.jobDir.resolve("solved.mph")))
            solved = j.jobDir.resolve("solved.mph");
        String flag = j.p.getOrDefault("solve", "1");
        boolean solve = !("0".equals(flag) || "false".equalsIgnoreCase(flag));
        boolean resume = solve && Files.isRegularFile(j.jobDir.resolve("solved"));
        Path load = resume ? solved : input;
        if (!Files.isRegularFile(load)) throw new JobFailure(2, "找不到模型 " + load);
        if (solve && !resume && "batch".equals(j.p.get("solver")))
            throw new JobFailure(3, "批处理求解未完成，缺少 solved 标记");
        j.loadedModel = load.toString();
        ModelUtil.initStandalone(false);
        j.runtime = ModelUtil.getComsolVersion();
        log("[driver] COMSOL " + j.runtime + " 读取 " + load);
        j.model = ModelUtil.loadCopy("m_export", load.toString());
        j.study = resolveStudy(j.model, j.p.getOrDefault("study", ""));
        if (solve && !resume) {
            try { j.model.study(j.study).run(); }
            catch (Exception e) { throw new JobFailure(3, errText(e)); }
            Files.createDirectories(solved.getParent());
            j.model.save(solved.toString());
            Files.writeString(j.jobDir.resolve("solved"), "ok");
        }
        Files.writeString(j.jobDir.resolve("exporting"), "ok");
        j.chunk = chunkSize(j);
        j.sols = listSols(j);
        int total = j.sols.stream().mapToInt(u -> u.n).sum();
        if (total == 0) throw new JobFailure(4, "所选研究 " + j.study + " 没有已存解，请选择含有所需解的模型");
        j.dataset = datasetFor(j, j.sols.get(0).tag);
        String wanted = j.p.getOrDefault("solution", "").trim();
        if (!wanted.isEmpty()) {
            if (!hasDataset(j, wanted) || j.sols.stream().noneMatch(u -> u.tag.equals(j.model.result().dataset(wanted).getString("solution"))))
                throw new JobFailure(2, "指定数据集不属于所选解范围 " + wanted);
            j.dataset = wanted;
        }
        j.pnames = studyParamNames(j.model, j.study);
        for (String tag : j.model.study(j.study).feature().tags()) {
            var step = j.model.study(j.study).feature(tag);
            j.details.add("研究步 " + tag + " · " + step.getType() + " · " + (step.isActive() ? "启用" : "停用"));
            if (step.isActive() && "Parametric".equals(step.getType())) {
                for (String key : Arrays.asList("pname", "plistarr", "punit")) {
                    try { j.details.add(tag + "." + key + " = " + String.join(" | ", step.getStringArray(key))); }
                    catch (RuntimeException ignored) { /* Property is optional in older models. */ }
                }
            }
        }
        planArtifacts(j);
        j.details.add("扫描参数 " + (j.pnames.length == 0 ? "无" : String.join(", ", j.pnames)));
        progressBlocks = j.blocks;
        for (int i = 1; i <= j.blocks; i++) {
            j.component = "";
            j.dataset = wanted.isEmpty() ? datasetFor(j, j.sols.get(0).tag) : wanted;
            j.currentBlock = i;
            progressBlock = i;
            String type = j.block(i, "type", "global").trim().toLowerCase(Locale.ROOT);
            Handler handler = HANDLERS.get(type);
            if (handler == null) throw new JobFailure(2, "未知导出类型 " + type);
            PROGRESS_LABEL = "导出块 " + i + "/" + j.blocks + " " + j.block(i, "name", type);
            progressImages = Arrays.asList("eigenslice", "slice2d", "image").contains(type);
            progress(0, progressImages ? j.blockFiles.get(i) : total, PROGRESS_LABEL);
            handler.run(j, i);
            progress(progressTotal, progressTotal, PROGRESS_LABEL);
            j.details.add("块 " + i + " " + j.block(i, "name", type) + " 已完成");
        }
        if (!j.expected.equals(j.artifacts.keySet())) throw new IOException("产物集合与配方不符");
    }

    static String eigenSuffix(boolean multi, int sequence, int mode, String plane) {
        return (multi ? "_s" + sequence : "") + "_m" + mode + "_" + plane.trim() + ".png";
    }

    static void planArtifacts(Job j) {
        for (int i = 1; i <= j.blocks; i++) {
            String kind = j.block(i, "type", "global").toLowerCase(Locale.ROOT);
            if (!HANDLERS.containsKey(kind)) throw new JobFailure(2, "未知导出类型 " + kind);
            String fallback = "global".equals(kind) ? "export" + i : ("eigenslice".equals(kind) ? "eigen" + i : kind);
            String name = j.block(i, "name", fallback);
            j.p.putIfAbsent("block." + i + ".name", name);
            String prefix = j.outname + "_" + name;
            List<Path> files = new ArrayList<>();
            if ("image".equals(kind)) files.add(j.outdir.resolve(prefix + "_all.png"));
            else if ("eigenslice".equals(kind) || "slice2d".equals(kind)) {
                String[] planes = split(j.block(i, "planes", "xy|zx|yz"));
                for (String p : planes) {
                    String plane = p.trim().toLowerCase(Locale.ROOT);
                    if (!Arrays.asList("xy","zx","yz").contains(plane)) throw new JobFailure(2, "无效切面 " + p);
                    if ("slice2d".equals(kind)) files.add(j.outdir.resolve(prefix + "_" + plane + ".png"));
                    else {
                        int max = Integer.parseInt(j.block(i, "maxmodes", "50"));
                        if (max <= 0) throw new JobFailure(2, "MaxModes 必须为正整数");
                        for (int n = 0; n < j.sols.size(); n++)
                            for (int k = 1; k <= Math.min(max, j.sols.get(n).n); k++)
                                files.add(j.outdir.resolve(prefix + eigenSuffix(j.sols.size()>1, n+1, k, plane)));
                    }
                }
            } else {
                files.add(csvTarget(j, i, name));
                if ("spectrum".equals(kind) && Boolean.parseBoolean(j.block(i, "plot", "false")))
                    files.add(j.outdir.resolve(prefix + ".png"));
            }
            j.blockFiles.put(i, files.size());
            for (Path file : files) {
                if (!j.outdir.equals(file.normalize().getParent()) || !j.expected.add(file))
                    throw new JobFailure(2, "产物重名或路径越界 " + file);
            }
        }
    }

    static void record(Job j, Path path, String description) throws IOException {
        if (!Files.isRegularFile(path) || Files.size(path) == 0) throw new IOException("缺少产物 " + path);
        if (j.artifacts.putIfAbsent(path, description) != null) throw new IOException("产物重名 " + path);
        if (progressImages) progress(progressDone + 1, progressTotal, PROGRESS_LABEL);
    }

    static void publish(Path staged, Path target) throws IOException {
        try { Files.move(staged, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING); }
        catch (AtomicMoveNotSupportedException e) { Files.move(staged, target, StandardCopyOption.REPLACE_EXISTING); }
    }

    static void writeManifest(Job j, int code, String error) throws IOException {
        List<String> lines = new ArrayList<>();
        Collections.addAll(lines, "# Export manifest", "", "- 状态 " + (code == 0 ? "完成" : "失败 · " + error),
                "- 作业 " + j.jobDir.getFileName(), "- 导出时间 " + java.time.OffsetDateTime.now(),
                "- 输入模型 " + j.p.get("model"), "- 实际读取 " + j.loadedModel,
                "- 研究 " + (j.study == null ? j.p.get("study") : j.study) + " · 解范围 " + j.p.getOrDefault("solscope", "study"),
                "- 配方 " + j.p.getOrDefault("recipe", "job.properties"),
                "- CLI " + j.p.getOrDefault("cli", "未记录") + " · driver " + DRIVER_VERSION + " · COMSOL " + j.runtime,
                "- 配置块 " + j.blocks + " · 计划产物 " + (j.blockFiles.isEmpty() ? "未展开" : Integer.toString(j.expected.size())) + " · 完成产物 " + j.artifacts.size() + " · 跳过非有限行 " + j.skipped,
                "", "## 解与产物", "");
        if (!j.loadedModel.isEmpty()) {
            Path source = Paths.get(j.loadedModel);
            lines.add("- 输入文件 " + Files.size(source) + " bytes · 修改时间 " + Files.getLastModifiedTime(source));
        }
        for (Path p : j.expected) if (!j.artifacts.containsKey(p)) lines.add("- 缺件 " + p.getFileName());
        for (SolUse u : j.sols) lines.add("- " + u.study + " / " + u.tag + " · 解 1–" + u.n);
        for (Map.Entry<Path,String> a : j.artifacts.entrySet())
            lines.add("- " + a.getKey().getFileName() + " · " + a.getValue() + " · " + Files.size(a.getKey()) + " bytes");
        for (String detail : j.details) lines.add("- " + detail);
        if (code != 0) lines.add("- 未完整交付，停止于块 " + j.currentBlock + "；其余请求见下方配方快照。");
        Collections.addAll(lines, "", "## 作业规格", "", "```text");
        j.p.forEach((k,v) -> lines.add(k + "=" + v));
        lines.add("```");
        String name = j.p.containsKey("resultdir") ? "EXPORT_MANIFEST.md" : j.jobDir.getFileName() + "_EXPORT_MANIFEST.md";
        Path target = j.outdir.resolve(name);
        Path part = Files.createTempFile(j.outdir, "manifest-", ".tmp");
        try {
            Files.write(part, lines, StandardCharsets.UTF_8);
            publish(part, target);
        } finally { Files.deleteIfExists(part); }
    }

    // ---------- 逐解取数核心 ----------
    // 为什么不直接用“所有解”(innerinput=all) 一次取完：
    // 远程 651 个解（λ 400→1050 步 1）的模型只写出了前 400 行。COMSOL 在解多、堆紧张时
    // 会静默少给列，而旧代码对 NaN 一律 continue 跳过，于是短表被当成正常结果落盘。
    // 现在先读每个解节点的解数 getSize()[1]，再按块显式指定解编号（manualindices）逐块取，
    // 每块都校验列数；取不满就报错，绝不静默写出不完整的表。
    static final class SolUse {
        String tag, study;
        int offset;
        int n;          // 解数；<=0 表示该节点没有可用解
    }

    interface SliceSink {
        // solTag 解节点；from 起始解编号；nCols 本块解数；v[节点][表达式][解]
        void slice(SolUse solution, int from, int nCols, double[][][] v) throws Exception;
    }

    // 多次数据的模型：每个解节点配一个独立的 Solution 数据集，
    // 直接改 dset1 的 solution 属性在多研究/多步骤模型里不生效，会只剩第一步的解。
    static String datasetFor(Job j, String solTag) {
        String tag = "dset_sol_" + solTag + (j.component.isEmpty() ? "" : "_" + j.component);
        try {
            if (!Arrays.asList(j.model.result().dataset().tags()).contains(tag)) {
                j.model.result().dataset().create(tag, "Solution");
            }
            j.model.result().dataset(tag).set("solution", solTag);
            if (!j.component.isEmpty()) j.model.result().dataset(tag).set("comp", j.component);
            return tag;
        } catch (Exception e) {
            throw new IllegalStateException("无法绑定解节点 " + solTag, e);
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

    static String solutionFamily(String type) {
        String t = type == null ? "" : type.toLowerCase(Locale.ROOT);
        if (t.contains("eigen") || t.contains("modeanalysis")) return "eigen";
        if (t.equals("time") || t.startsWith("transient") || t.startsWith("timedependent")) return "time";
        if (t.equals("parametric") || t.startsWith("stationary") || t.startsWith("frequency") || t.startsWith("wavelength")) return "stationary";
        return "";
    }

    static boolean activeSequence(Model m, String study, String tag) {
        Set<String> activeSteps = new HashSet<>(), activeFamilies = new HashSet<>(), disabledFamilies = new HashSet<>();
        boolean enabledPhysics = false;
        for (String step : m.study(study).feature().tags()) {
            var feature = m.study(study).feature(step);
            String type = feature.getType();
            if (Arrays.asList("Parametric", "Batch", "BatchSweep", "ClusterSweep").contains(type)) continue;
            if (feature.isActive()) {
                activeSteps.add(step);
                activeFamilies.add(solutionFamily(type));
                enabledPhysics = true;
            } else disabledFamilies.add(solutionFamily(type));
        }
        if (!enabledPhysics) return false;
        boolean bound = false, enabledBinding = false, disabledBinding = false;
        for (String f : m.sol(tag).feature().tags()) {
            var feature = m.sol(tag).feature(f);
            if (!"StudyStep".equals(feature.getType())) continue;
            String step = feature.getString("studystep");
            if (step == null || step.isEmpty()) continue;
            bound = true;
            if (activeSteps.contains(step)) enabledBinding = true; else disabledBinding = true;
        }
        if (bound && !enabledBinding) return false;
        if (bound && !disabledBinding) return true;
        // Stored/compound sequences may not identify a single step. With conflicting steps of the
        // same solution type the default scope cannot establish ownership; explicit all remains available.
        String family = solutionFamily(m.sol(tag).getType());
        if (family.isEmpty()) return disabledFamilies.isEmpty();
        if (disabledFamilies.contains(family)) return false;
        return activeFamilies.contains(family) || activeFamilies.contains("");
    }

    static List<SolUse> listSols(Job j) {
        List<SolUse> list = new ArrayList<>();
        boolean all = "all".equalsIgnoreCase(j.p.getOrDefault("solscope", "study"));
        int offset = 0;
        Set<String> related = new HashSet<>(Arrays.asList(j.model.study(j.study).getSolverSequences("All")));
        for (String t : j.model.sol().tags()) {
            String study;
            try { study = j.model.sol(t).study(); }
            catch (RuntimeException e) { study = ""; } // Unattached stored solution.

            if (!all && !(j.study.equals(study) || ((study == null || study.isEmpty()) && related.contains(t)))) continue;
            if (j.model.sol(t).isEmpty()) continue;
            if (!all && !activeSequence(j.model, j.study, t)) {
                j.details.add("未选择解 " + t + " · 研究步已停用或存储解归属不唯一");
                continue;
            }
            int[] size = j.model.sol(t).getSize();
            if (size.length < 2 || size[1] <= 0) continue;
            SolUse u = new SolUse();
            u.tag = t; u.study = study == null || study.isEmpty() ? (related.contains(t) ? j.study : "") : study;
            u.n = size[1]; u.offset = offset; offset += u.n;
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
        int got = (a == null || a.length == 0 || a[0] == null) ? 0 : a[0].length;
        if (a != null) for (double[] row : a) if (row == null || row.length != expect) { got = row == null ? 0 : row.length; break; }
        if (got != expect) {
            throw new IllegalStateException(where + " 取数不完整：要 " + expect + " 列，实得 " + got
                    + " 列（节点 " + node + "）。可能是解没存全，或 Java 堆不够（当前 max="
                    + (Runtime.getRuntime().maxMemory() >> 20) + "MB）；确认后加大 -Xmx 重试。");
        }
        return a;
    }

    static LinkedHashMap<String, int[]> walkSols(Job j, String[] nodes, SliceSink sink) throws Exception {
        return walkSols(j, nodes, Integer.MAX_VALUE, sink);
    }

    static LinkedHashMap<String, int[]> walkSols(Job j, String[] nodes, int limit, SliceSink sink) throws Exception {
        LinkedHashMap<String, int[]> stat = new LinkedHashMap<>();
        int chunk = j.chunk;
        int totN = 0;
        for (SolUse u : j.sols) { if (u.n > 0) totN += u.n; }
        totN = Math.min(totN, limit);
        int doneN = 0;
        progress(0, totN, PROGRESS_LABEL);
        for (SolUse u : j.sols) {
            int count = Math.min(u.n, limit - doneN);
            if (count <= 0) break;
            String dset = datasetFor(j, u.tag);
            for (String nd : nodes) j.model.result().numerical(nd).set("data", dset);
            int got = 0;
            for (int from = 1; from <= count; from += chunk) {
                int to = Math.min(count, from + chunk - 1);
                int nCols = to - from + 1;
                for (String nd : nodes) pinChunk(j, nd, from, to);
                double[][][] v = new double[nodes.length][][];
                for (int q = 0; q < nodes.length; q++) {
                    v[q] = realChunk(j, nodes[q], nCols, "解节点 " + u.tag + " 第 " + from + "…" + to + " 个解");
                }
                sink.slice(u, from, nCols, v);
                got += nCols;
                doneN += nCols;
                progress(doneN, totN, PROGRESS_LABEL);
            }
            for (String nd : nodes) unpinChunk(j, nd);
            stat.put(u.tag, new int[] { count, got });
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
        j.skipped += nan;
        if ("1".equals(j.block(i, "allownan", "0").trim())) {
            j.details.add("块 " + i + " 按 Allownan=1 跳过 " + nan + " 行");
            System.out.println("[driver] 警告: 有 " + nan + " 个解算不出数（NaN/Inf），已按 Allownan=1 跳过");
            return;
        }
        throw new IllegalStateException("有 " + nan + " 个解算不出数（NaN/Inf），拒绝写出不完整的表；"
                + "若这些点本来无定义，可在该块加 Allownan=1。heap max="
                + (Runtime.getRuntime().maxMemory() >> 20) + "MB");
    }

    static String csvCell(String text) {
        if (text.indexOf(',') < 0 && text.indexOf('"') < 0 && !text.contains("\n") && !text.contains("\r")) return text;
        return "\"" + text.replace("\"", "\"\"") + "\"";
    }

    // A physical expression with an explicit unit evaluates to a dimensionless value.
    static String[] columnExpressions(Job j, int i, String[] expressions, String[] columns) {
        String[] units = j.blockArr(i, "units");
        if (units.length != 0 && units.length != expressions.length) throw new IllegalArgumentException("Units 与 Expr 长度不同");
        String[] result = expressions.clone();
        for (int k = 0; k < result.length; k++) {
            String unit = units.length == 0 ? "" : units[k].trim();
            String expr = result[k].replace(" ", "");
            if (unit.isEmpty() && columns[k].endsWith("_nm") && expr.matches("c_const/(?:[A-Za-z0-9_]+\\.)?freq")) unit = "nm";
            if (!unit.isEmpty()) result[k] = "(" + result[k] + ")/1[" + unit + "]";
        }
        return result;
    }

    static final String WAVE_EXPR = "(c_const/real(freq))/1[nm]";

    static double[] wavelengths(Job j, SolUse u, int from, int count) {
        String tag = "gev_identity_wave";
        try {
            if (!Arrays.asList(j.model.result().numerical().tags()).contains(tag))
                j.model.result().numerical().create(tag, "EvalGlobal");
            j.model.result().numerical(tag).set("data", datasetFor(j, u.tag));
            j.model.result().numerical(tag).set("expr", WAVE_EXPR);
            pinChunk(j, tag, from, from + count - 1);
            return realChunk(j, tag, count, "波长标识")[0];
        } catch (RuntimeException e) {
            // Time/stationary solutions may have no frequency.
            return new double[0];
        }
    }

    static final class CsvStream implements AutoCloseable {
        final Job job;
        final Path target, part;
        final BufferedWriter writer;
        final String[] columns;
        final boolean addWave;
        int rows;
        boolean committed;
        CsvStream(Job j, Path path, String[] cols) throws IOException {
            job = j; target = path; columns = cols.clone();
            Set<String> unique = new HashSet<>(Arrays.asList("study_tag", "sol_tag", "sol_num", "solution_index"));
            for (String c : cols) if (c.isBlank() || !unique.add(c)) throw new IllegalArgumentException("CSV 列名为空、重复或保留：" + c);
            addWave = !unique.contains("lambda_nm");
            part = Files.createTempFile(target.getParent(), "csv-", ".part");
            writer = Files.newBufferedWriter(part, StandardCharsets.UTF_8);
            for (String c : columns) { writer.write(csvCell(c)); writer.write(','); }
            if (addWave) writer.write("lambda_nm,");
            writer.write("study_tag,sol_tag,sol_num,solution_index");
            writer.newLine();
        }
        void row(double[] values, SolUse u, int local, double[] wave, int col) throws IOException {
            for (double value : values) {
                if (Double.isFinite(value)) writer.write(Double.toString(value));
                writer.write(',');
            }
            if (addWave) {
                if (wave.length > col && Double.isFinite(wave[col])) writer.write(Double.toString(wave[col]));
                writer.write(',');
            }
            writer.write(csvCell(u.study) + "," + csvCell(u.tag) + "," + local + "," + (u.offset + local));
            writer.newLine(); rows++;
        }
        void commit() throws IOException {
            if (rows == 0) throw new IOException("没有可输出的有限数据行");
            writer.close();
            publish(part, target);
            committed = true;
            record(job, target, rows + " 行 · " + String.join(", ", columns));
        }
        public void close() throws IOException {
            try { writer.close(); } finally { if (!committed) Files.deleteIfExists(part); }
        }
    }

    static void writeRows(Job j, int i, String node, String[] cols, boolean modes) throws Exception {
        String name = j.block(i, "name", "export" + i);
        int limit = modes ? Integer.parseInt(j.block(i, "maxmodes", "50").trim()) : Integer.MAX_VALUE;
        if (limit < 1) throw new IllegalArgumentException("MaxModes 必须为正整数");
        List<String> header = new ArrayList<>();
        if (modes) header.add("mode");
        Collections.addAll(header, cols);
        try (CsvStream out = new CsvStream(j, csvTarget(j, i, name), header.toArray(new String[0]))) {
            int[] nan = {0};
            logSols(walkSols(j, new String[] {node}, limit, (u, from, n, v) -> {
                double[] wave = out.addWave ? wavelengths(j, u, from, n) : new double[0];
                for (int c = 0; c < n; c++) {
                    double[] row = new double[header.size()];
                    int off = modes ? 1 : 0;
                    if (modes) row[0] = u.offset + from + c;
                    for (int q = 0; q < cols.length; q++) row[q+off] = v[0][q][c];
                    if (!Arrays.stream(row).allMatch(Double::isFinite)) { nan[0]++; continue; }
                    out.row(row, u, from+c, wave, c);
                }
            }));
            requireNoLoss(j, i, nan[0]);
            out.commit();
        }
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
        expr0 = columnExpressions(j, i, expr0, cols0);
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

        writeRows(j, i, node, cols, false);
    }

    // spectrum：透射/反射谱（CSV 必出，曲线图可选 Plot=true）
    static void exportSpectrum(Job j, int i) throws Exception {
        String name = j.block(i, "name", "spectrum");
        if (j.block(i, "expr", "").trim().isEmpty()) {
            j.p.put("block." + i + ".expr", "(c_const/ewfd.freq)/1[nm]|abs(ewfd.S21)^2|abs(ewfd.S11)^2");
            j.p.put("block." + i + ".cols", "lambda_nm|T00|R00");
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
        j.model.result(tag).feature("glob1").set("descr", new String[] { "T00", "R00" });
        try { j.model.result(tag).set("title", name); } catch (Exception ignore) { }
        j.model.result(tag).run();
        Path png = j.outdir.resolve(j.outname + "_" + name + ".png");
        exportPng(j, i, tag, png);
        record(j, png, "零阶透反射曲线 · 数据集 " + j.dataset);
        System.out.println("[driver] 写出 " + png);
    }

    // ---------- image ----------
    // 一次出四张：三维默认视图一张（三个正交切片），xy / xz / zy 三个二维正投影各一张。
    // expr（默认 ewfd.normE）、solnum（默认 1）、at（切面位置，默认 auto=几何中心）、
    // plane（at 作用在哪个面上，兼容旧配方，默认 xy）、edges（on|off，默认 off）、
    // width/height（像素，默认 800x600）、title（图题后缀）
    // image 块的 SolNum 是「全部解里的第几个」（与 CSV 的行序一致），
    // 但 Solution 数据集的 solution 属性一次只能绑一个解节点（合法值就是 sol1…solN），
    // 解号只能在该节点内数。所以这里把全局解号翻成 (解节点, 节点内序号)。
    static String[] pickSol(Job j, String solnum) throws Exception {
        int want;
        try {
            want = Integer.parseInt(solnum.trim());
        } catch (NumberFormatException e) {
            throw new Exception("SolNum 不是整数: " + solnum);
        }
        if (want <= 0) throw new Exception("SolNum 必须从 1 开始，收到 " + want);
        List<SolUse> sols = j.sols;
        int acc = 0;
        StringBuilder ranges = new StringBuilder();
        for (SolUse s : sols) {
            if (s.n <= 0) continue;
            if (want > acc && want <= acc + s.n) return new String[] { s.tag, Integer.toString(want - acc) };
            acc += s.n;
            ranges.append(ranges.length() == 0 ? "" : "，").append(s.tag).append(" 1-").append(acc);
        }
        throw new Exception("SolNum " + want + " 超出范围（共 " + acc + " 个解；" + ranges + "）");
    }

    static void exportImage(Job j, int i) throws Exception {
        // 场量用分量（Ex / Ey），不再用 normE 模值；逗号分隔则逐分量各出一套图
        String exprs = j.block(i, "expr", "ewfd.Ex,ewfd.Ey").trim();
        String[] list = exprs.split(",");
        int n = 0;
        for (String s : list) if (!s.trim().isEmpty()) n++;
        int k = 0;
        java.util.List<Path[]> perComp = new java.util.ArrayList<>();
        java.util.List<String> sfxList = new java.util.ArrayList<>();
        // 分面图只是拼总表用的中间件：写到作业临时目录，拼完即删，outdir 里只留组合图
        if (j.tmpdir == null) j.tmpdir = Files.createDirectories(j.jobDir.resolve("render-work"));
        Path work = j.tmpdir.resolve("img_" + i);
        try {
            Files.createDirectories(work);
            for (String s : list) {
                String e = s.trim();
                if (e.isEmpty()) continue;
                String fileSfx = "", tagSfx = "";
                if (n > 1) {
                    String shortName = e.substring(e.lastIndexOf('.') + 1);
                    fileSfx = "_" + shortName;
                    tagSfx = "_" + k;
                }
                perComp.add(exportImageOne(j, i, e, tagSfx, fileSfx, work));
                sfxList.add(tagSfx);
                k++;
            }
            // 拼版：每个分量一块 —— 左边三维，右边上 xy、下 xz 与 zy 均分（用户指定）
            if (perComp.isEmpty()) throw new IllegalArgumentException("场图 Expr 为空");
            {
                java.util.List<String> labels = new java.util.ArrayList<>();
                for (String s : list) { String e = s.trim(); if (!e.isEmpty()) labels.add(e); }
                String name0 = j.block(i, "name", "image");
                Path all = j.outdir.resolve(j.outname + "_" + name0 + "_all.png");
                composeFieldSheet(perComp, labels, sfxList, i, all);
                record(j, all, "场图 " + String.join(", ", labels));
            }
        } finally {
            try { deleteTree(work); } catch (Exception ignore) { }
        }
    }

    /** 场图总表：每个分量一块 —— 左三维（占满整块高度），
     *  右边上 x-y（方形，宽度 = 两张侧面 + 间隔），下 x-z 与 z-y 并排铺满其余高度；
     *  二维只取场本身，坐标轴与色标由这里自己画（COMSOL 的框去不掉）。 */
    static void composeFieldSheet(java.util.List<Path[]> comps, java.util.List<String> labels,
                                  java.util.List<String> sfx, int i, Path out) throws Exception {
        final int BLOCK_H = S(2400), GAP = S(90), PAD = S(110), TITLE = S(90);
        final int AXM = S(96), CBM = S(150);
        java.awt.Font fTitle = new java.awt.Font("Microsoft YaHei", java.awt.Font.PLAIN, S(48));
        java.awt.Font fNum = new java.awt.Font("Microsoft YaHei", java.awt.Font.PLAIN, S(26));
        // 先按第一块量出各图的宽高比，再算几何：块高固定，侧面两张并排撑满 x-y 的宽度
        java.awt.image.BufferedImage[] probe = new java.awt.image.BufferedImage[4];
        Path[] c0 = comps.get(0);
        for (int k = 0; k < 4; k++) probe[k] = javax.imageio.ImageIO.read(c0[k].toFile());
        double ax3 = probe[0].getWidth() / (double) probe[0].getHeight();
        double axS = probe[2].getWidth() / (double) probe[2].getHeight();
        // 每张二维图占一个格：左轴留白 AXM + 场宽 + 右色标 CBM；侧面两格正好铺满 x-y 那一格
        // BLOCK_H = sXY + GAP + hSd，且 wSd = (sXY - AXM - CBM) / 2、hSd = wSd / axS
        double k = 1.0 / (2.0 * axS);
        int sXY = (int) Math.round((BLOCK_H - GAP + (AXM + CBM) * k) / (1 + k));
        int wSd = Math.max(40, (sXY - AXM - CBM) / 2);
        int hSd = (int) Math.round(wSd / axS);
        int w3 = (int) Math.round(ax3 * BLOCK_H);
        int blockW = w3 + GAP + AXM + sXY + CBM;
        int W = PAD * 2 + comps.size() * blockW + Math.max(0, comps.size() - 1) * GAP * 3;
        int H = PAD * 2 + TITLE + BLOCK_H;
        java.awt.image.BufferedImage sheet = new java.awt.image.BufferedImage(W, H, java.awt.image.BufferedImage.TYPE_INT_RGB);
        java.awt.Graphics2D g = sheet.createGraphics();
        g.setRenderingHint(java.awt.RenderingHints.KEY_TEXT_ANTIALIASING, java.awt.RenderingHints.VALUE_TEXT_ANTIALIAS_ON);
        g.setRenderingHint(java.awt.RenderingHints.KEY_ANTIALIASING, java.awt.RenderingHints.VALUE_ANTIALIAS_ON);
        g.setColor(java.awt.Color.WHITE);
        g.fillRect(0, 0, W, H);
        int[] ramp = sampleRamp(probe[0]);
        for (int idx = 0; idx < comps.size(); idx++) {
            Path[] cp = comps.get(idx);
            String sf = sfx.get(idx);
            int x0 = PAD + idx * (blockW + GAP * 3);
            int y0 = PAD + TITLE;
            g.setColor(new java.awt.Color(25, 25, 25));
            g.setFont(fTitle);
            g.drawString(labels.size() > idx ? labels.get(idx) : "", x0, PAD + S(40));
            g.setFont(fNum);
            g.setColor(new java.awt.Color(60, 60, 60));
            g.drawString("三维", x0, y0 - S(18));
            g.drawImage(scaledTo(cp[0], BLOCK_H), x0, y0, null);      // 三维：占满整块高（自带色标在下方）
            int px = x0 + w3 + GAP + AXM;
            g.drawString("x-y", px, y0 - S(18));
            drawPanel(g, scaledTo(cp[1], sXY), px, y0, YAX.get(i + "|" + sf + "|xy"), RNG.get(i + "|" + sf + "|xy"), ramp, fNum);
            int yb = y0 + sXY + GAP;
            int xz = x0 + w3 + GAP + AXM;
            int zy = xz + wSd + AXM + CBM;
            g.drawString("x-z", xz, yb - S(18));
            drawPanel(g, scaledTo(cp[2], hSd), xz, yb, YAX.get(i + "|" + sf + "|xz"), RNG.get(i + "|" + sf + "|xz"), ramp, fNum);
            g.drawString("z-y", zy, yb - S(18));
            drawPanel(g, scaledTo(cp[3], hSd), zy, yb, YAX.get(i + "|" + sf + "|yz"), RNG.get(i + "|" + sf + "|yz"), ramp, fNum);
        }
        g.dispose();
        writePng(sheet, out);
        System.out.println("[driver] 写出 " + out + "（" + W + "×" + H + " px @" + DPI + " dpi，"
                + comps.size() + " 个分量）");
    }

    /** 一个二维面板：贴场 + 左边一条竖轴（刻度与数字）+ 右侧竖色标 */
    static void drawPanel(java.awt.Graphics2D g, java.awt.image.BufferedImage im, int x, int y,
                          double[] yax, double[] rng, int[] ramp, java.awt.Font f) {
        int w = im.getWidth(), h = im.getHeight();
        g.drawImage(im, x, y, null);
        int axisX = x - S(14);
        g.setColor(new java.awt.Color(70, 70, 70));
        g.drawLine(axisX, y, axisX, y + h - 1);
        if (yax != null) {
            for (int k = 0; k <= 4; k++) {
                double val = yax[1] - (yax[1] - yax[0]) * k / 4.0;
                int ty = y + (int) Math.round(h * k / 4.0);
                if (ty > y + h - 1) ty = y + h - 1;
                g.drawLine(axisX - S(8), ty, axisX, ty);
                String s = fmt(val);
                int sw = g.getFontMetrics(f).stringWidth(s);
                g.setColor(new java.awt.Color(35, 35, 35));
                g.setFont(f);
                g.drawString(s, axisX - S(12) - sw, ty + S(9));
                g.setColor(new java.awt.Color(70, 70, 70));
            }
        }
        if (rng != null && ramp != null) {
            int bw = S(20), bh = (int) (h * 0.62), bx = x + w + S(34), by = y + (h - bh) / 2;
            for (int k = 0; k < bh; k++) {
                int ci = (int) Math.round((bh - 1 - k) * (ramp.length - 1) / (double) (bh - 1));
                g.setColor(new java.awt.Color(ramp[ci] | 0xFF000000, true));
                g.fillRect(bx, by + k, bw, 1);
            }
            g.setColor(new java.awt.Color(70, 70, 70));
            g.drawRect(bx, by, bw, bh);
            double span = Math.abs(rng[1] - rng[0]);
            int e = rng[1] == 0 || span == 0 ? 0 : (int) Math.floor(Math.log10(Math.max(Math.abs(rng[0]), Math.abs(rng[1]))));
            double sc = Math.pow(10, e);
            g.setFont(f);
            String hi = fmt(rng[1] / sc), lo = fmt(rng[0] / sc);
            g.drawString(hi, bx + bw + S(10), by + S(10));
            g.drawString(lo, bx + bw + S(10), by + bh);
            g.drawString("×10^" + e, bx, by - S(14));
        }
    }

    static String fmt(double v) {
        double a = Math.abs(v);
        if (a != 0 && (a < 0.001 || a >= 10000)) return String.format(java.util.Locale.ROOT, "%.2e", v);
        if (Math.abs(v - Math.rint(v)) < 1e-6) return String.format(java.util.Locale.ROOT, "%.0f", v);
        return String.format(java.util.Locale.ROOT, "%.2f", v);
    }

    /** 从三维图里那条横向色标采样颜色，得到 0..1 的色带（COMSOL 自己的配色） */
    static int[] sampleRamp(java.awt.image.BufferedImage im) {
        int[] def = new int[] { 0x3b4cc0, 0x2fa8e0, 0x59d3c0, 0xa8e05f, 0xf6d743, 0xf08a3e, 0xc62828 };
        try {
            int w = im.getWidth(), h = im.getHeight();
            int bestY = -1, bestRun = 0, bestX = -1;
            for (int y = h - 1; y >= Math.max(0, h - 260); y--) {
                int run = 0, x0 = -1, bestLocal = 0, localX = -1;
                for (int x = 0; x < w; x++) {
                    int rgb = im.getRGB(x, y);
                    int r = (rgb >> 16) & 255, gg = (rgb >> 8) & 255, b = rgb & 255;
                    int mx = Math.max(r, Math.max(gg, b)), mn = Math.min(r, Math.min(gg, b));
                    boolean sat = mx > 60 && (mx - mn) > 40;
                    if (sat) { if (run == 0) x0 = x; run++; if (run > bestLocal) { bestLocal = run; localX = x0; } }
                    else run = 0;
                }
                if (bestLocal > bestRun) { bestRun = bestLocal; bestY = y; bestX = localX; }
            }
            if (bestY < 0 || bestRun < 40) return def;
            int[] ramp = new int[64];
            for (int k = 0; k < 64; k++) {
                int x = bestX + (int) Math.round(k * (bestRun - 1) / 63.0);
                ramp[k] = im.getRGB(x, bestY) & 0xFFFFFF;
            }
            return ramp;
        } catch (Exception e) {
            return def;
        }
    }

    /** 按目标高度等比缩放（保持宽高比） */
    static java.awt.image.BufferedImage scaledTo(Path p, int h) throws Exception {
        java.awt.image.BufferedImage im = javax.imageio.ImageIO.read(p.toFile());
        if (im == null) return new java.awt.image.BufferedImage(1, h, java.awt.image.BufferedImage.TYPE_INT_RGB);
        int w = Math.max(1, (int) Math.round(im.getWidth() * (double) h / im.getHeight()));
        java.awt.image.BufferedImage o = new java.awt.image.BufferedImage(w, h, java.awt.image.BufferedImage.TYPE_INT_RGB);
        java.awt.Graphics2D g = o.createGraphics();
        g.setRenderingHint(java.awt.RenderingHints.KEY_INTERPOLATION,
                java.awt.RenderingHints.VALUE_INTERPOLATION_BILINEAR);
        g.drawImage(im, 0, 0, w, h, null);
        g.dispose();
        return o;
    }

    static Path[] exportImageOne(Job j, int i, String expr, String tagSfx, String fileSfx, Path dir) throws Exception {
        String name = j.block(i, "name", "image");
        String solnum = j.block(i, "solnum", "1").trim();
        String at = j.block(i, "at", "auto").trim();
        String edges = j.block(i, "edges", "on").trim();   // 默认画边：保留每个域的边界线
        String title = j.block(i, "title", "").trim();
        GRID_ON = "on".equalsIgnoreCase(j.block(i, "grid", "off").trim());   // 默认不画栅格

        // 用切面自己的数据集（CutPlane）：解落在哪个数据集由它决定。
        // 之前把绘图组钉在 firstDataset（模型里第一个 Solution 数据集）上，周期结构模型里
        // 第一个数据集常常不是「研究1//解 1」，解号对不上就从窗口外裁剪，图全白。
        String dsData = "ds_img_" + i + tagSfx;
        String solTag = j.block(i, "soltag", "").trim();
        String[] pick;
        if (solTag.isEmpty()) pick = pickSol(j, solnum);
        else {
            SolUse selected = j.sols.stream().filter(u -> solTag.equals(u.tag)).findFirst()
                    .orElseThrow(() -> new IllegalArgumentException("所选研究中没有解 " + solTag));
            int local = Integer.parseInt(solnum);
            if (local < 1 || local > selected.n) throw new IllegalArgumentException("解号超出 " + solTag + " 的范围");
            pick = new String[]{solTag, Integer.toString(local)};
        }
        if (tagSfx.isEmpty() || tagSfx.equals("_0")) {
            SolUse u = j.sols.stream().filter(x -> x.tag.equals(pick[0])).findFirst().get();
            double[] wave = wavelengths(j, u, Integer.parseInt(pick[1]), 1);
            j.details.add("场图 " + name + " · " + u.study + "/" + u.tag + "/" + pick[1]
                    + (wave.length > 0 && Double.isFinite(wave[0]) ? " · " + wave[0] + " nm" : ""));
        }
        String localSol = pick[1];
        log("[driver] 场图解 " + solnum + " → 解节点 " + pick[0] + " 第 " + localSol + " 个");
        if (hasDataset(j, dsData)) {
            log("[driver] 场图: 删除旧数据集 " + dsData);
            j.model.result().dataset().remove(dsData);
        }
        log("[driver] 场图: 建 Solution 数据集 " + dsData + "，solution=" + pick[0]);
        j.model.result().dataset().create(dsData, "Solution");
        j.model.result().dataset(dsData).set("solution", pick[0]);
        log("[driver] 场图: 数据集绑定完成，开始三维组");

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
        String tag3 = "pg_img3_" + i + tagSfx;
        if (!hasResult(j, tag3)) j.model.result().create(tag3, "PlotGroup3D");
        // 三维组必须给显式视图：新建的 PlotGroup3D 若沿用当前视图（常是二维视图），
        // 三维切片会被裁剪在可视范围外，导出成空白白图
        trySet(j.model.result(tag3), "view", "auto");   // auto = COMSOL 默认三维视角，和 GUI 里看到的一致
        j.model.result(tag3).set("data", dsData);
        j.model.result(tag3).set("solnum", localSol);
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
        // 色标放下方：竖排在右侧会拉得比模型长得多
        trySet(j.model.result(tag3), "legendpos", "bottom");
        // 坐标框（栅格）由 Grid 字段单独控制，这里受 Edges 控制的是域/单元边界线
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
        // 画布按几何长宽比给（不再固定 4:3）：细长样品出竖长画布，扁的给横长
        int w3 = Integer.parseInt(j.block(i, "width", "1200").trim());
        if (w3 <= 0) w3 = 1200;
        double spanXY = Math.max(bb[1] - bb[0], bb[3] - bb[2]);
        double spanZ = bb[5] - bb[4];
        double asp3 = spanXY > 0 ? spanZ / spanXY : 1;
        // 画布随拼版一起放大 SCALE 倍：拼版把三维图拉到 BLOCK_H 高，源图小了会被拉伸糊掉
        final int BASE = (int) Math.round(900 * SCALE), CAP = (int) Math.round(2400 * SCALE),
                MINW = (int) Math.round(700 * SCALE);
        int h3, ww3;
        if (asp3 >= 1) { h3 = Math.min(CAP, Math.max(BASE, (int) Math.round(BASE * asp3))); ww3 = Math.max(MINW, (int) Math.round(h3 / asp3)); }
        else { ww3 = Math.min(CAP, Math.max(BASE, (int) Math.round(BASE / Math.max(asp3, 0.05)))); h3 = Math.max(MINW, (int) Math.round(ww3 * asp3)); }
        Path png3 = dir.resolve(j.outname + "_" + name + fileSfx + "_3d.png");
        exportPng(j, i, tag3, png3, ww3, h3);
        cropWhite(png3, 12);   // 画布按内容裁掉四周白边，不再被 4:3 硬比例撑出大片空白
        System.out.println("[driver] 写出 " + png3);

        String v2 = "";   // 第一次 run 之后按绘图组挑现成的二维视图
        // 2) 三个二维正投影：CutPlane 数据集 + 2D 绘图组，正对着看
        int pxW = Integer.parseInt(j.block(i, "width", "1200").trim());
        int pxH = Integer.parseInt(j.block(i, "height", "0").trim());   // 0 = 按切面真实长宽比算高度
        if (pxW <= 0) pxW = 1200;
        if (pxH < 0) pxH = 0;
        // 真实比例出图：不做任何拉伸（二维视图保持 1:1）
        String[][] planes = {
                { "xy", "_xy", "XY" }, { "xz", "_xz", "XZ" }, { "yz", "_zy", "ZY" } };
        Path xzPng = null, zyPng = null, xyPng = null;
        for (String[] pl : planes) {
            String plane = pl[0], suffix = pl[1], caption = pl[2];
            double pos = "xy".equals(plane) ? zc : ("xz".equals(plane) ? yc : xc);
            String dtag = "dsp2d_" + i + tagSfx + "_" + plane;
            if (!hasDataset(j, dtag)) j.model.result().dataset().create(dtag, "CutPlane");
            j.model.result().dataset(dtag).set("data", dsData);
            j.model.result().dataset(dtag).set("quickplane", plane);
            trySet(j.model.result().dataset(dtag), offsetKey(plane), Double.toString(pos));

            String pg = "pg2d_" + i + tagSfx + "_" + plane;
            if (!hasResult(j, pg)) j.model.result().create(pg, "PlotGroup2D");
            j.model.result(pg).set("data", dtag);
            j.model.result(pg).set("solnum", localSol);
            int[] px = canvasSize(pxW, pxH, plane, bb);
            // 竖图（细长截面）把色标挪到下方：右侧色标会吃掉本就只有几百像素的宽度，
            // COMSOL 为保 1:1 会把纵轴撑大，数据只剩中间一条
            // 色标竖排在右侧；拼成一张时它正好落在两图中间（图例在中间）
            trySet(j.model.result(pg), "legendpos", "right");
            if (!hasResultFeature(j, pg, "surf1")) j.model.result(pg).create("surf1", "Surface");
            j.model.result(pg).feature("surf1").set("expr", expr);
            // 二维视图必须在 run() 之后才出现在 view 合法值里；先 run 再挑视图、设轴范围、再 run
            // 视图用 COMSOL 的 auto：它把轴范围正好框到数据，和 GUI 里看到的一致；
            // 手工设 view2 轴范围反而会按 1:1 把轴撑大、留一圈白
            trySet(j.model.result(pg), "view", "auto");
            decorate(j.model.result(pg), edges, caption + " 切面", title, "");
            // 二维不要 COMSOL 那个把模型包起来的坐标框：关掉轴，改由后面画一条竖线
            trySet(j.model.result(pg), "axisactive", "off");
            j.model.result(pg).run();
            // 竖图太窄，标题带量名会折成三行，只用平面名
            applyTitle(j.model.result(pg), caption + " 切面",
                    px[1] > px[0] ? caption + " 切面" : title, "");
            Path png2 = dir.resolve(j.outname + "_" + name + fileSfx + suffix + ".png");
            // 竖图（xz/zy）右侧留一条竖直色标：两张拼起来后色标正好落在中间；
            // 画布宽度按实测绘图框自适应（色标会吃掉宽度，窄了纵轴会被 1:1 撑大）
            boolean wantLegend = !"yz".equals(plane);
            // 画布宽度 = 数据宽 + 装饰宽度（色标/刻度标签）。给足，宁可多留白再裁，
            // 也不能让绘图框窄到被 1:1 撑大纵轴（那样数据只剩中间一条）。
            double spX, spY;
            if ("xy".equals(plane)) { spX = bb[1] - bb[0]; spY = bb[3] - bb[2]; }
            else if ("xz".equals(plane)) { spX = bb[1] - bb[0]; spY = bb[5] - bb[4]; }
            else { spX = bb[3] - bb[2]; spY = bb[5] - bb[4]; }
            int hPx = px[1];
            int wPx = (int) Math.round(hPx * (spX / spY)) + (wantLegend ? 380 : 150);
            wPx = Math.max(200, Math.min(4096, wPx));
            exportPng(j, i, pg, png2, wPx, hPx, false, true);   // 二维只导场，装饰由拼版时自己画
            // 记下该面的数值范围与纵轴范围，拼版时用来画色标与刻度
            String rk = i + "|" + tagSfx + "|" + plane;
            String rr = tryGetString(j.model.result(pg).feature("surf1"), "rangeactualminmax");
            if (rr != null && rr.indexOf(',') > 0) {
                try {
                    RNG.put(rk, new double[] { Double.parseDouble(rr.substring(0, rr.indexOf(',')).trim()),
                            Double.parseDouble(rr.substring(rr.indexOf(',') + 1).trim()) });
                } catch (NumberFormatException ignore) { }
            }
            if ("xy".equals(plane)) YAX.put(rk, new double[] { bb[2], bb[3] });
            else if ("xz".equals(plane)) YAX.put(rk, new double[] { bb[4], bb[5] });
            else YAX.put(rk, new double[] { bb[4], bb[5] });
            cropWhite(png2, 10);
            stripBox(png2);   // 去掉 COMSOL 那个包住模型的框线，保留左侧刻度数字与右侧色标
            if ("xz".equals(plane)) xzPng = png2;
            else if ("yz".equals(plane)) zyPng = png2;
            else { xyPng = png2; System.out.println("[driver] 写出 " + png2); }
        }
        return new Path[] { png3, xyPng, xzPng, zyPng };
    }

    // 二维正投影用哪个视图：二维绘图组必须挂一个 ResultView2D。
    // 直接 set("view","auto") 不行——导出时 auto 会退回到三维视图，切开的三维视图在二维组里
    // 只剩一条无限细的线（实测导出的图整张空白）。所以模型里没有就自己建一个。
    static String view2d(Job j) {
        try {
            for (String v : j.model.view().tags()) {
                String t = j.model.view(v).getType();
                if (t != null && t.contains("ResultView2D")) return v;
            }
            String tag = "view2d_export";
            if (!Arrays.asList(j.model.view().tags()).contains(tag)) j.model.view().create(tag, "View2D");
            return tag;
        } catch (Exception e) {
            System.out.println("[driver] 警告: 建二维视图失败（" + e.getMessage() + "），用 auto");
            return "";
        }
    }

    // 三维切片图用哪个视图：优先现成的三维视图，没有就建一个
    static String view3d(Job j) {
        try {
            for (String v : j.model.view().tags()) {
                String t = j.model.view(v).getType();
                if (t != null && t.contains("ModelView3D")) return v;
            }
            String tag = "view3d_export";
            if (!Arrays.asList(j.model.view().tags()).contains(tag)) j.model.view().create(tag, "ModelView3D");
            return tag;
        } catch (Exception ignore) { }
        return "";
    }

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
        else if ("xz".equals(plane)) { x0 = bb[0]; x1 = bb[1]; y0 = bb[4]; y1 = bb[5]; }
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
        /** 量出图片里绘图框（黑色边框矩形）的范围：{x0,x1,y0,y1}；找不到返回 null */
    static int[] frameBox(java.awt.image.BufferedImage img) {
        int w = img.getWidth(), h = img.getHeight();
        int[] rows = new int[h], cols = new int[w];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                int rgb = img.getRGB(x, y);
                int r = (rgb >> 16) & 0xFF, g = (rgb >> 8) & 0xFF, bl = rgb & 0xFF;
                if (r < 80 && g < 80 && bl < 80) { rows[y]++; cols[x]++; }
            }
        int y0 = -1, y1 = -1, x0 = -1, x1 = -1;
        for (int y = 0; y < h; y++) if (rows[y] > w * 0.4) { if (y0 < 0) y0 = y; y1 = y; }
        for (int x = 0; x < w; x++) if (cols[x] > h * 0.4) { if (x0 < 0) x0 = x; x1 = x; }
        if (x0 < 0 || y0 < 0) return null;
        return new int[] { x0, x1, y0, y1 };
    }

    /** 二维图按数据长宽比自适应画布宽度：色标吃掉宽度时，绘图框会被压窄、纵轴被 1:1 撑大。
     *  导出后量一次绘图框，宽了/窄了按比例补画布宽度（最多试 3 次）。 */
    static Path export2dFit(Job j, int i, String plotGroup, Path target,
                            int pxW, String plane, double[] bb, boolean legend) throws Exception {
        int[] px = canvasSize(pxW, 0, plane, bb);
        double spanX, spanY;
        if ("xy".equals(plane)) { spanX = bb[1] - bb[0]; spanY = bb[3] - bb[2]; }
        else if ("xz".equals(plane)) { spanX = bb[1] - bb[0]; spanY = bb[5] - bb[4]; }
        else { spanX = bb[3] - bb[2]; spanY = bb[5] - bb[4]; }
        double want = spanX / spanY;
        int w = px[0], h = px[1];
        for (int attempt = 0; attempt < 3; attempt++) {
            exportPng(j, i, plotGroup, target, w, h, legend);
            java.awt.image.BufferedImage img = javax.imageio.ImageIO.read(target.toFile());
            int[] fb = img == null ? null : frameBox(img);
            if (fb == null) break;
            double got = (double) (fb[1] - fb[0]) / Math.max(1, fb[3] - fb[2]);
            if (Math.abs(got / want - 1) < 0.03) break;
            long need = Math.round((fb[3] - fb[2]) * want);      // 绘图框应有的宽度
            long delta = need - (fb[1] - fb[0]);
            w = (int) Math.max(200, Math.min(4096, w + delta));
            if (w >= 4095) break;
        }
        return target;
    }

static int[] canvasSize(int w, int h, String plane, double[] bb) {
        if (h > 0) return new int[] { w, h };
        double spanX, spanY;
        if ("xy".equals(plane)) { spanX = bb[1] - bb[0]; spanY = bb[3] - bb[2]; }
        else if ("xz".equals(plane)) { spanX = bb[1] - bb[0]; spanY = bb[5] - bb[4]; }
        else if ("zx".equals(plane)) { spanX = bb[5] - bb[4]; spanY = bb[1] - bb[0]; }
        else { spanX = bb[3] - bb[2]; spanY = bb[5] - bb[4]; }
        if (spanX <= 0 || spanY <= 0) return new int[] { w, 900 };
        double aspect = spanX / spanY;                 // 横向 / 纵向
        // 分面图要供 300 dpi 的拼版使用，故留足像素：短边 ≥1200，长边 ≥3600（单边上限 4096）
        int shortSide = (int) Math.round(800 * SCALE), longSide = (int) Math.round(2400 * SCALE), maxSide = 4096;
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
        // 色标/刻度标签的宽度在二维循环里按实测补（见 fit2dCanvas）
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
        if (maxModes <= 0) throw new IllegalArgumentException("MaxModes 必须为正整数");
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
                } catch (Exception ex) { throw new IllegalStateException("无法选择模态 " + solTag + "/" + k, ex); }
                boolean any = false;
                for (String plane : planes) {
                    try {
                        j.model.result(tag).feature("sli1").set("quickplane", plane.trim());
                        j.model.result(tag).feature("sli1").set(offsetKey(plane.trim()), j.block(i, "at", "0").trim());
                        j.model.result(tag).run();
                        Path png = j.outdir.resolve(j.outname + "_" + j.block(i, "name", "eigen" + i)
                                + eigenSuffix(multiSol, solIdx, k, plane));
                        exportPng(j, i, tag, png);
                        System.out.println("[driver] 写出 " + png);
                        record(j, png, solTag + "/" + k + " " + plane);
                        written++; any = true;
                    } catch (Exception ex) {
                        throw new IOException("缺少模态切片 " + solTag + "/" + k + "/" + plane, ex);
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
            record(j, png, expr + " · " + plane + " · 数据集 " + j.dataset);
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
        if (!dim.equals("line") && !dim.equals("surface")) throw new IllegalArgumentException("Dim 必须为 line 或 surface");
        expr = columnExpressions(j, i, expr, cols);
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
        writeRows(j, i, node, cols, false);
    }

    // ---------- bigtable：通用原始大表（全局参数 + 谱线 + 各域吸收） ----------
    static void exportBigTable(Job j, int i) throws Exception {
        String name = j.block(i, "name", "bigtable");
        String domSpec = j.block(i, "absdomains", "auto").trim();
        String absExpr = j.block(i, "absexpr", "ewfd.Qh").trim();
        String paramSpec = j.block(i, "params", "all").trim();

        String component = j.block(i, "component", "").trim();
        if (component.isEmpty()) {
            String[] components = j.model.component().tags();
            if (components.length != 1 && !domSpec.equalsIgnoreCase("none"))
                throw new IllegalArgumentException("多个组件，请在 bigtable 指定 Component");
            if (components.length > 0) component = components[0];
        } else if (!Arrays.asList(j.model.component().tags()).contains(component)) {
            throw new IllegalArgumentException("找不到组件 " + component);
        }
        if (j.model.component().tags().length > 1 && !component.isEmpty()) {
            j.component = component;
            j.dataset = datasetFor(j, j.sols.get(0).tag);
        }
        String material = j.block(i, "material", "").trim();
        String selection = j.block(i, "selection", "").trim();
        if ((!selection.isEmpty() && !material.isEmpty()) || (!domSpec.equalsIgnoreCase("auto") && (!selection.isEmpty() || !material.isEmpty())))
            throw new IllegalArgumentException("Material、Selection、显式 AbsDomains 只能选择一种");
        String species = (material.isEmpty() && selection.isEmpty()) ? "ITO" : "abs";
        Set<String> requested = new LinkedHashSet<>();
        for (String key : paramSpec.split("[,|]")) if (!key.trim().isEmpty()) requested.add(key.trim());

        // 1) 全局参数表达式
        List<String> pExps = new ArrayList<>();
        List<String> pNames = new ArrayList<>();
        if (!paramSpec.equalsIgnoreCase("none")) {
            for (String v : j.model.param().varnames()) {
                if (paramSpec.equalsIgnoreCase("all") || requested.remove(v)) {
                    pExps.add(v); pNames.add(v + "_val");
                }
            }
        }

        if (!paramSpec.equalsIgnoreCase("all") && !paramSpec.equalsIgnoreCase("none") && !requested.isEmpty())
            throw new IllegalArgumentException("未知 Params 参数 " + requested);

        String[] specExpr = { "(c_const/ewfd.freq)/1[nm]", "ewfd.freq/1[THz]", "abs(ewfd.S21)^2", "abs(ewfd.S11)^2",
                "ewfd.Ttotal", "ewfd.Rtotal", "arg(ewfd.S21)", "1-ewfd.Ttotal-ewfd.Rtotal", "ewfd.Pin" };
        String[] specCols = { "lambda_nm", "freq_THz", "T00", "R00", "T_total", "R_total",
                "phase_S21_rad", "A_1-T-R", "Pin_W" };

        // 2) 吸收域：编号 + 英文名（auto = 材料名含 ITO 的域，按 z 中心自动排序）
        int[] domIds;
        String[] domNames;
        if (domSpec.equalsIgnoreCase("auto")) {
            List<Integer> cand = new ArrayList<>();
            if (!selection.isEmpty()) {
                for (int e : j.model.component(component).selection(selection).entities(3)) cand.add(e);
            } else {
                for (String mt : j.model.component(component).material().tags()) {
                    String label = j.model.component(component).material(mt).label();
                    boolean match = material.isEmpty() ? label != null && label.toLowerCase(Locale.ROOT).contains("ito")
                            : material.equals(mt) || material.equalsIgnoreCase(label);
                    if (!match) continue;
                    for (int e : j.model.component(component).material(mt).selection().entities(3))
                        if (!cand.contains(e)) cand.add(e);
                }
            }
            if (cand.isEmpty()) throw new IllegalArgumentException("未找到吸收域，请核对 Component、Material、Selection 或 AbsDomains");
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
                domNames[z] = (order.length <= 3 && species.equals("ITO") ? layerName(z, order.length) + "_" : "") + "d" + domIds[z];
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

        Set<Integer> uniqueDomains = new HashSet<>();
        for (int d = 0; d < domIds.length; d++) {
            if (domIds[d] <= 0 || domNames[d].isBlank()) throw new IllegalArgumentException("域号必须为正、域名不能为空");
            if (!uniqueDomains.add(domIds[d])) throw new IllegalArgumentException("重复吸收域 " + domIds[d]);
            j.details.add("吸收域 " + domNames[d] + " · " + component + " 域 " + domIds[d] + " · " + absExpr);
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
        for (String nm : domNames) { cols.add("Qrh_" + species + "_" + nm + "_W"); cols.add("A_" + species + "_" + nm + "_pct"); }
        cols.add("Qrh_" + species + "_total_W"); cols.add("A_" + species + "_total_pct");

        Path target = csvTarget(j, i, name);
        int[] st = new int[3]; // rows, non-finite source values, zero Pin
        int base = nP + specExpr.length;
        try (CsvStream out = new CsvStream(j, target, cols.toArray(new String[0]))) {
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
                    if (pin == 0) st[2]++;
                    double sumQ = 0;
                    for (int z = 0; z < nDom; z++) {
                        double q = v[z + 1][0][c];
                        if (Double.isNaN(q) || Double.isInfinite(q)) { ok = false; break; }
                        row[base + z * 2] = q;
                        row[base + z * 2 + 1] = normalizedAbsorption(q, pin);
                        sumQ += q;
                    }
                    if (!ok) { st[1]++; continue; }
                    row[base + nDom * 2] = nDom == 0 ? Double.NaN : sumQ;
                    row[base + nDom * 2 + 1] = nDom == 0 ? Double.NaN : normalizedAbsorption(sumQ, pin);
                    out.row(row, tag, from+c, new double[0], c);
                    st[0]++;
                }
            });
            logSols(stat);
            if (st[0] == 0) throw new IllegalStateException("大表没有取到任何数据（检查解节点与研究设置）");
            requireNoLoss(j, i, st[1]);
            out.commit();
        }
        if (st[2] > 0) j.details.add("Pin_W 为零 " + st[2] + " 行，归一化吸收列留空");
        if (nDom == 0) j.details.add("未计算分域吸收，分域合计列留空");
    }

    static double normalizedAbsorption(double watts, double inputWatts) {
        return inputWatts == 0 ? Double.NaN : 100.0 * watts / inputWatts;
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
        pinChunk(j, tag, 1, 1);
        double[][] r = realChunk(j, tag, 1, "吸收域 " + dom);
        if (r.length != 2 || r[1].length != 1) throw new IllegalStateException("吸收域缺少体积或高度 " + dom);
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
        final String[] expr = columnExpressions(j, i, exprIn, colsIn);
        final String[] cols = colsIn;
        String node = "gmod_" + i;
        if (!Arrays.asList(j.model.result().numerical().tags()).contains(node)) {
            j.model.result().numerical().create(node, "EvalGlobal");
        }
        j.model.result().numerical(node).set("data", j.dataset);
        j.model.result().numerical(node).set("expr", expr);
        j.model.result().numerical(node).set("descr", cols);
        writeRows(j, i, node, cols, true);
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
        if ("xz".equals(plane) || "zx".equals(plane)) return "quicky";
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

    /** 三维是否画坐标框（栅格）；由 image 块的 Grid 字段控制，默认关 */
    static boolean GRID_ON = false;

    /** 场图总表的分辨率倍率：以 300 dpi 出图，像素密度在旧版基础上 ×1.5。
     *  拼版尺寸、字号、分面导出画布、装饰线宽都按它缩放，改一处即可整体提高/降低分辨率。 */
    static final double SCALE = 1.5;

    /** PNG 里写入的 dpi（COMSOL 导出节点本身也用 300） */
    static final int DPI = 300;

    /** 按 SCALE 缩放一个像素尺寸 */
    static int S(double v) { return (int) Math.round(v * SCALE); }

    /** 二维面数值范围与纵轴范围：key = 块号|分量后缀|平面 */
    static final java.util.Map<String, double[]> RNG = new java.util.HashMap<>();
    static final java.util.Map<String, double[]> YAX = new java.util.HashMap<>();

    static void exportPng(Job j, int i, String plotGroup, Path target) throws Exception {
        exportPng(j, i, plotGroup, target, 0, 0);
    }

    static void exportPng(Job j, int i, String plotGroup, Path target, int w, int h) throws Exception {
        exportPng(j, i, plotGroup, target, w, h, true);
    }

    static void exportPng(Job j, int i, String plotGroup, Path target, int w, int h, boolean legend) throws Exception {
        exportPng(j, i, plotGroup, target, w, h, legend, false);
    }

    static void exportPng(Job j, int i, String plotGroup, Path target, int w, int h, boolean legend, boolean plain) throws Exception {
        String tag = "img_" + i + "_" + Math.abs((plotGroup + target.toString()).hashCode() % 1000000);
        if (!Arrays.asList(j.model.result().export().tags()).contains(tag)) {
            j.model.result().export().create(tag, "Image");
        }
        j.model.result().export(tag).set("plotgroup", plotGroup);
        j.model.result().export(tag).set("imagetype", "png");
        j.model.result().export(tag).set("size", "manualweb");
        j.model.result().export(tag).set("unit", "px");
        trySet(j.model.result().export(tag), "resolution", "300");   // 300 dpi，PNG 里带 dpi 元数据
        // 300 dpi 下 9pt 字≈37px：细长面板上字会吃掉画面，按短边缩放字号
        int shortSide = Math.min(w, h);
        if (shortSide > 0) {
            int fs = (int) Math.round(shortSide * 0.03 * 72.0 / 300.0);
            trySet(j.model.result().export(tag), "fontsize",
                    Integer.toString(Math.max(3, Math.min(9, fs))));
        }
        j.model.result().export(tag).set("width", w > 0 ? Integer.toString(w) : Integer.toString(Math.max(1, pxOf(j, i, "width", 1200))));
        j.model.result().export(tag).set("height", h > 0 ? Integer.toString(h) : Integer.toString(Math.max(1, pxOf(j, i, "height", 900))));
        // 图题/色标/坐标轴的总闸在导出节点上；绘图组里那些开关不参与导出渲染
        Object ex = j.model.result().export(tag);
        trySet(ex, "options1d", "on");
        trySet(ex, "options2d", plain ? "off" : "on");   // plain = 只要场，COMSOL 的框/刻度/色标/标题一概不画
        trySet(ex, "options3d", "on");
        trySet(ex, "title1d", "on");
        trySet(ex, "title2d", "on");
        trySet(ex, "title3d", "off");   // 三维的标题由拼版自己写
        trySet(ex, "legend1d", "on");
        trySet(ex, "legend2d", legend ? "on" : "off");
        trySet(ex, "legend3d", legend ? "on" : "off");
        // 图下方的 COMSOL 徽标、三维左下角的坐标三轴，出图时都不需要
        trySet(ex, "logo1d", "off");
        trySet(ex, "logo2d", "off");
        trySet(ex, "logo3d", "off");
        trySet(ex, "axisorientation", "off");
        trySet(ex, "grid", GRID_ON ? "on" : "off");   // 三维坐标框/栅格，默认关
        trySet(ex, "showgrid", "off");
        Path part = Paths.get(target.toString() + ".part.png");
        j.model.result().export(tag).set("pngfilename", part.toString().replace("\\", "/"));
        Files.createDirectories(target.getParent());
        j.model.result().export(tag).run();
        publish(part, target);
    }

    /** 把 COMSOL 二维图里那个包住模型的方框拆掉：左右保留（左侧刻度数字、右侧色标），
     *  只把框线本身和框内侧的刻度桩去掉，再重新拼成一张无框的图。 */
    static void stripBox(Path png) {
        try {
            java.awt.image.BufferedImage img = javax.imageio.ImageIO.read(png.toFile());
            if (img == null) return;
            int w = img.getWidth(), h = img.getHeight();
            boolean[] darkRow = new boolean[h], darkCol = new boolean[w];
            int[] rowCnt = new int[h], colCnt = new int[w];
            for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
                int rgb = img.getRGB(x, y);
                int r = (rgb >> 16) & 255, gg = (rgb >> 8) & 255, b = rgb & 255;
                if (r < 140 && gg < 140 && b < 140) { rowCnt[y]++; colCnt[x]++; }
            }
            for (int y = 0; y < h; y++) darkRow[y] = rowCnt[y] > w * 0.45;
            for (int x = 0; x < w; x++) darkCol[x] = colCnt[x] > h * 0.45;
            int top = -1, bottom = -1, left = -1, right = -1;
            for (int y = 0; y < h; y++) if (darkRow[y]) { if (top < 0) top = y; bottom = y; }
            // 只取最主要的一对竖线（最左、色标左侧那根）：右侧色标也会形成长竖线，取比它靠左的最后一根
            int leftLine = -1, rightLine = -1;
            for (int x = 0; x < w; x++) if (darkCol[x]) { if (leftLine < 0) leftLine = x; else rightLine = x; }
            if (top < 0 || leftLine < 0 || rightLine <= leftLine) return;
            int inset = 8;
            int x0 = leftLine + inset, x1 = rightLine - inset, y0 = top + inset, y1 = bottom - inset;
            if (x1 - x0 < 20 || y1 - y0 < 20) return;
            java.awt.image.BufferedImage title = img.getSubimage(0, 0, w, Math.max(1, top));
            java.awt.image.BufferedImage leftBand = img.getSubimage(0, top, Math.max(1, leftLine), bottom - top + 1);
            java.awt.image.BufferedImage field = img.getSubimage(x0, y0, x1 - x0, y1 - y0);
            java.awt.image.BufferedImage rightBand = img.getSubimage(rightLine + 1, top, Math.max(1, w - rightLine - 1), bottom - top + 1);
            java.awt.image.BufferedImage foot = bottom + 1 < h
                    ? img.getSubimage(0, bottom + 1, w, h - bottom - 1) : null;
            int outW = leftBand.getWidth() + field.getWidth() + rightBand.getWidth();
            int outH = title.getHeight() + field.getHeight() + (foot == null ? 0 : foot.getHeight());
            java.awt.image.BufferedImage out = new java.awt.image.BufferedImage(outW, outH, java.awt.image.BufferedImage.TYPE_INT_RGB);
            java.awt.Graphics2D g = out.createGraphics();
            g.setColor(java.awt.Color.WHITE);
            g.fillRect(0, 0, outW, outH);
            g.drawImage(title, (outW - title.getWidth()) / 2, 0, null);
            int y = title.getHeight();
            g.drawImage(leftBand, 0, y, null);
            g.drawImage(field, leftBand.getWidth(), y, null);
            g.drawImage(rightBand, leftBand.getWidth() + field.getWidth(), y, null);
            if (foot != null) g.drawImage(foot, leftBand.getWidth(), y + field.getHeight(), null);
            g.dispose();
            writePng(out, png);
        } catch (Exception ignore) { }
    }

    // ---------- PNG 写出（带 dpi） ----------
    // ImageIO 写 PNG 不带 pHYs，dpi 就丢了（看图软件按 72 dpi 换算物理尺寸，图会显得很大很糊）。
    // 这里在 IHDR 之后插一个 pHYs 块：X=Y=DPI 的每米像素数，单位米。
    static void writePng(java.awt.image.BufferedImage img, Path target) throws IOException {
        java.io.ByteArrayOutputStream bos = new java.io.ByteArrayOutputStream();
        javax.imageio.ImageIO.write(img, "png", bos);
        byte[] png = bos.toByteArray();
        try {
            int ppm = (int) Math.round(DPI / 0.0254);       // 300 dpi = 11811 px/m
            byte[] type = { 'p', 'H', 'Y', 's' };
            byte[] data = new byte[9];
            data[0] = (byte) (ppm >>> 24); data[1] = (byte) (ppm >>> 16);
            data[2] = (byte) (ppm >>> 8); data[3] = (byte) ppm;
            System.arraycopy(data, 0, data, 4, 4);          // Y 方向同值
            data[8] = 1;                                    // 单位：米
            java.util.zip.CRC32 crc = new java.util.zip.CRC32();
            crc.update(type);
            crc.update(data);
            int c = (int) crc.getValue();
            java.io.ByteArrayOutputStream o = new java.io.ByteArrayOutputStream(png.length + 25);
            o.write(png, 0, 33);                            // 8 字节签名 + IHDR(25)
            o.write(new byte[] { 0, 0, 0, 9 });             // pHYs 长度
            o.write(type);
            o.write(data);
            o.write(new byte[] { (byte) (c >>> 24), (byte) (c >>> 16), (byte) (c >>> 8), (byte) c });
            o.write(png, 33, png.length - 33);
            png = o.toByteArray();
        } catch (Exception ignore) { }
        Files.write(target, png);
    }

    /** 多行拼图：每行内各图等高对齐、整行居中；行与行之间留 gap。不缩放，保持原始像素 */
    static void stitchGrid(java.util.List<Path[]> rows, Path out, int gap) throws Exception {
        java.util.List<java.util.List<java.awt.image.BufferedImage>> imgs = new java.util.ArrayList<>();
        int W = 0, H = gap * (rows.size() - 1);
        int[] rowH = new int[rows.size()];
        for (int r = 0; r < rows.size(); r++) {
            java.util.List<java.awt.image.BufferedImage> line = new java.util.ArrayList<>();
            int w = gap * Math.max(0, rows.get(r).length - 1);
            for (Path p : rows.get(r)) {
                java.awt.image.BufferedImage im = p == null ? null : javax.imageio.ImageIO.read(p.toFile());
                line.add(im);
                if (im != null) {
                    w += im.getWidth();
                    rowH[r] = Math.max(rowH[r], im.getHeight());
                }
            }
            imgs.add(line);
            W = Math.max(W, w);
            H += rowH[r];
        }
        java.awt.image.BufferedImage canvas = new java.awt.image.BufferedImage(W, H, java.awt.image.BufferedImage.TYPE_INT_RGB);
        java.awt.Graphics2D g = canvas.createGraphics();
        g.setColor(java.awt.Color.WHITE);
        g.fillRect(0, 0, W, H);
        int y = 0;
        for (int r = 0; r < rows.size(); r++) {
            int rowW = gap * Math.max(0, imgs.get(r).size() - 1);
            for (java.awt.image.BufferedImage im : imgs.get(r)) if (im != null) rowW += im.getWidth();
            int x = 0;   // 行左对齐，像一张清单
            for (java.awt.image.BufferedImage im : imgs.get(r)) {
                if (im != null) {
                    g.drawImage(im, x, y + (rowH[r] - im.getHeight()) / 2, null);
                    x += im.getWidth() + gap;
                }
            }
            y += rowH[r] + gap;
        }
        g.dispose();
        writePng(canvas, out);
    }
    // 裁掉四周纯白边（COMSOL 导出的画布按字符比例给，二维细长切面会留大片空白）
    static void cropWhite(Path png, int pad) {
        try {
            java.awt.image.BufferedImage img = javax.imageio.ImageIO.read(png.toFile());
            int w = img.getWidth(), h = img.getHeight();
            int x0 = w, y0 = h, x1 = -1, y1 = -1;
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    int rgb = img.getRGB(x, y);
                    int r = (rgb >> 16) & 255, g = (rgb >> 8) & 255, b = rgb & 255;
                    if (r < 250 || g < 250 || b < 250) {   // 非白像素
                        if (x < x0) x0 = x;
                        if (x > x1) x1 = x;
                        if (y < y0) y0 = y;
                        if (y > y1) y1 = y;
                    }
                }
            }
            if (x1 < 0) return;                            // 全白，不动
            x0 = Math.max(0, x0 - pad); y0 = Math.max(0, y0 - pad);
            x1 = Math.min(w - 1, x1 + pad); y1 = Math.min(h - 1, y1 + pad);
            if (x0 == 0 && y0 == 0 && x1 == w - 1 && y1 == h - 1) return;
            java.awt.image.BufferedImage sub = img.getSubimage(x0, y0, x1 - x0 + 1, y1 - y0 + 1);
            java.awt.image.BufferedImage out = new java.awt.image.BufferedImage(
                    sub.getWidth(), sub.getHeight(), java.awt.image.BufferedImage.TYPE_INT_RGB);
            java.awt.Graphics2D g2 = out.createGraphics();
            g2.setColor(java.awt.Color.WHITE);
            g2.fillRect(0, 0, out.getWidth(), out.getHeight());
            g2.drawImage(sub, 0, 0, null);
            g2.dispose();
            writePng(out, png);
        } catch (Exception e) {
            System.out.println("[driver] 警告: 裁白边失败 " + e.getMessage());
        }
    }

    // 两张图横向拼一张（等高对齐、顶部对齐，中间留 gap 像素白缝）
    static void stitchH(Path left, Path right, Path out, int gap) {
        try {
            java.awt.image.BufferedImage a = javax.imageio.ImageIO.read(left.toFile());
            java.awt.image.BufferedImage b = javax.imageio.ImageIO.read(right.toFile());
            int h = Math.max(a.getHeight(), b.getHeight());
            int w = a.getWidth() + gap + b.getWidth();
            java.awt.image.BufferedImage img = new java.awt.image.BufferedImage(
                    w, h, java.awt.image.BufferedImage.TYPE_INT_RGB);
            java.awt.Graphics2D g2 = img.createGraphics();
            g2.setColor(java.awt.Color.WHITE);
            g2.fillRect(0, 0, w, h);
            g2.drawImage(a, 0, 0, null);
            g2.drawImage(b, a.getWidth() + gap, 0, null);
            g2.dispose();
            writePng(img, out);
        } catch (Exception e) {
            throw new IllegalStateException("拼图失败: " + e.getMessage(), e);
        }
    }

    // 导出尺寸：height=0 在配方里是「按切面长宽比自动算」，但导出节点要求宽高都 > 0
    // （COMSOL 6.4 直接报 属性值无效 - 高度 x > 0），所以 0 一律换回一个正数
    static int pxOf(Job j, int i, String key, int def) {
        try {
            int v = Integer.parseInt(j.block(i, key, Integer.toString(def)).trim());
            return v > 0 ? v : def;
        } catch (Exception e) {
            return def;
        }
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
                if (!model.study(study).feature(ft).isActive()) continue;
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
            throw new JobFailure(2, "找不到指定研究 " + want);
        }
        if (tags.length == 0) throw new JobFailure(2, "模型里没有研究");
        return tags[0];
    }

    static String[] split(String s) {
        if (s == null || s.trim().isEmpty()) return new String[0];
        return s.split("\\|", -1);
    }

    /** 模型文件名去掉 .mph —— 用作 output 下的产物子文件夹名（与模型同名） */
    static String modelBase(Path modelPath) {
        String n = modelPath == null || modelPath.getFileName() == null
                ? "" : modelPath.getFileName().toString();
        if (n.toLowerCase().endsWith(".mph")) n = n.substring(0, n.length() - 4);
        n = n.trim();
        if (n.isEmpty()) n = "model";
        // 目录名里去掉 Windows 不允许的字符（模型名一般干净，兜底）
        return n.replaceAll("[\\\\/:*?\"<>|]", "_");
    }

    static void deleteTree(Path root) throws IOException {
        if (!Files.exists(root)) return;
        try (java.util.stream.Stream<Path> entries = Files.walk(root)) {
            for (Path p : entries.sorted(Comparator.reverseOrder()).toArray(Path[]::new)) Files.deleteIfExists(p);
        }
    }
}
