// COMSOL 导出驱动
// 只做三件事：把模型副本跑完 -> 按作业文件里的 Export 块取数 -> 写 CSV。
// 不读参数、不改参数、不改网格、不改任何模型设置；模型里存什么就算什么。
//
// 用法: ExportDriver <job.properties>
// 作业文件由 cli.ps1 生成，键值用 key=value，数组用 | 分隔：
//   model=<.mph 绝对路径>
//   study=<研究标签>
//   outdir=<输出目录>
//   outname=<不含扩展名的文件名>
//   blocks=1
//   block.1.type=global
//   block.1.name=TR
//   block.1.expr=c_const/ewfd.freq|abs(ewfd.S21)^2|abs(ewfd.S11)^2
//   block.1.cols=lambda_nm|T|R
//
// 退出码: 0 成功; 2 用法/文件错误; 3 求解失败; 4 导出失败

import com.comsol.model.Model;
import com.comsol.model.util.ModelUtil;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;

public class ExportDriver {

    public static void main(String[] args) {
        if (args.length < 1) {
            System.err.println("usage: ExportDriver <job.properties>");
            System.exit(2);
        }
        // 自己解析 key=value：java.util.Properties 会把 Windows 路径里的反斜杠当转义符
        Map<String, String> p;
        try {
            p = readSpec(Paths.get(args[0]));
        } catch (IOException e) {
            System.err.println("读作业文件失败: " + e.getMessage());
            System.exit(2);
            return;
        }

        String modelPath = p.get("model");
        String studyTag  = p.getOrDefault("study", "");
        String outdir    = p.get("outdir");
        String outname   = p.get("outname");
        int blocks       = Integer.parseInt(p.getOrDefault("blocks", "0").trim());

        if (modelPath == null || !Files.isRegularFile(Paths.get(modelPath))) {
            System.err.println("模型不存在: " + modelPath);
            System.exit(2);
        }
        if (blocks <= 0) {
            System.err.println("作业文件里没有 Export 块");
            System.exit(2);
        }

        Path jobDir = Paths.get(args[0]).toAbsolutePath().getParent();
        // 已求解的模型跟 CSV 一样规范命名，放到 models/ 下（不塞进 logs）
        String modelsDirProp = p.getOrDefault("modelsdir", "").trim();
        Path modelsDir = modelsDirProp.isEmpty()
                ? Paths.get(outdir).toAbsolutePath().getParent().resolve("models")
                : Paths.get(modelsDirProp).toAbsolutePath();
        String savedName = outname + ".mph";
        Path solvedDir = modelsDir.resolve("solved");
        Path solvedModel = solvedDir.resolve(savedName);
        if (!Files.isRegularFile(solvedModel)) {
            Path legacy = jobDir.resolve("solved.mph");   // 兼容旧作业目录
            if (Files.isRegularFile(legacy)) solvedModel = legacy;
        }
        Path mkSolved = jobDir.resolve("solved");
        Path mkExporting = jobDir.resolve("exporting");
        Path mkExported = jobDir.resolve("exported");

        Path tmp = null;
        try {
            // 永远在副本上算：不改用户文件，也不在模型目录留 .lock
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
            System.out.flush();

            String study = resolveStudy(model, studyTag);
            if (!resume) {
                System.out.println("[driver] 求解研究: " + study);
                System.out.flush();
                long t0 = System.currentTimeMillis();
                try {
                    model.study(study).run();
                } catch (Exception e) {
                    System.err.println("求解失败: " + e.getMessage());
                    System.exit(3);
                }
                System.out.println("[driver] 求解完成，耗时 " + (System.currentTimeMillis() - t0) / 1000 + " s");
                System.out.flush();
                // 存一份带解场的模型：之后被打断只需重跑导出，不必再算
                Files.createDirectories(solvedDir);
                model.save(solvedModel.toString());
                System.out.println("[driver] 已求解模型: " + solvedModel);
                Files.write(mkSolved, "ok".getBytes(StandardCharsets.UTF_8));
            } else {
                System.out.println("[driver] 续跑：跳过求解");
            }
            Files.write(mkExporting, "ok".getBytes(StandardCharsets.UTF_8));

            String dataset = firstDataset(model);
            String[] pnames = studyParamNames(model, study);
            if (pnames.length > 0) {
                System.out.println("[driver] 参数化扫描变量: " + String.join(", ", pnames));
                System.out.flush();
            }
            Files.createDirectories(Paths.get(outdir));

            for (int i = 1; i <= blocks; i++) {
                String type = p.getOrDefault("block." + i + ".type", "global").trim();
                String name = p.getOrDefault("block." + i + ".name", "export" + i).trim();
                if (!"global".equalsIgnoreCase(type)) {
                    System.err.println("暂不支持的导出类型: " + type);
                    System.exit(4);
                }
                String[] expr0 = split(p.getOrDefault("block." + i + ".expr", ""));
                String[] cols0 = split(p.getOrDefault("block." + i + ".cols", ""));
                if (expr0.length == 0 || cols0.length != expr0.length) {
                    System.err.println("Export 块 " + name + " 的 expr/cols 数量不匹配");
                    System.exit(4);
                }
                // 扫描变量放最前面，这样一行就知道是第几组
                int m = pnames.length;
                String[] expr = new String[m + expr0.length];
                String[] cols = new String[m + cols0.length];
                for (int k = 0; k < m; k++) { expr[k] = pnames[k]; cols[k] = pnames[k]; }
                System.arraycopy(expr0, 0, expr, m, expr0.length);
                System.arraycopy(cols0, 0, cols, m, cols0.length);

                // 逐个解节点、逐个解编号取数：不依赖默认“全部解”的行为
                java.util.List<double[]> found = new java.util.ArrayList<>();
                try {
                    String node = "gev_export_" + i;
                    model.result().numerical().create(node, "EvalGlobal");
                    model.result().numerical(node).set("data", dataset);
                    model.result().numerical(node).set("expr", expr);
                    model.result().numerical(node).set("descr", cols);
                    for (String solTag : model.sol().tags()) {
                        model.result().dataset(dataset).set("solution", solTag);
                        for (int k = 1; k <= 200; k++) {
                            try {
                                model.result().numerical(node).set("solnum", Integer.toString(k));
                                double[][] a = model.result().numerical(node).getReal();
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
                                for (double[] prev : found) if (java.util.Arrays.equals(prev, row)) { dup = true; break; }
                                if (!dup) found.add(row);
                            } catch (Exception inner) {
                                break;
                            }
                        }
                    }
                } catch (Exception e) {
                    System.err.println("取数失败: " + e.getMessage());
                    System.exit(4);
                    return;
                }
                if (found.isEmpty()) {
                    System.err.println("没有取到任何解（检查解节点与表达式）");
                    System.exit(4);
                    return;
                }
                double[][] data = new double[expr.length][found.size()];
                for (int c = 0; c < found.size(); c++)
                    for (int q = 0; q < expr.length; q++) data[q][c] = found.get(c)[q];
                System.out.println("[driver] 共取到 " + found.size() + " 个解");

String fileName = (blocks == 1) ? outname : outname + "_" + name;
                Path target = Paths.get(outdir).resolve(fileName + ".csv");
                writeCsv(target, data, expr, cols);
                System.out.println("[driver] 写出 " + target);
                System.out.flush();
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
            if (tmp != null) {
                try { deleteTree(tmp); } catch (Exception ignore) { }
            }
        }
    }

    private static Map<String, String> readSpec(Path file) throws IOException {
        String text = new String(Files.readAllBytes(file), StandardCharsets.UTF_8);
        if (!text.isEmpty() && text.charAt(0) == '\uFEFF') text = text.substring(1);
        Map<String, String> map = new LinkedHashMap<>();
        for (String line : text.split("\\r?\\n")) {
            String s2 = line.trim();
            if (s2.isEmpty() || s2.startsWith("#")) continue;
            int i = s2.indexOf('=');
            if (i <= 0) continue;
            map.put(s2.substring(0, i).trim(), s2.substring(i + 1).trim());
        }
        return map;
    }

    private static String[] studyParamNames(Model model, String study) {
        java.util.List<String> names = new java.util.ArrayList<>();
        try {
            for (String ft : model.study(study).feature().tags()) {
                if (!"Parametric".equals(model.study(study).feature(ft).getType())) continue;
                String[] pn = model.study(study).feature(ft).getStringArray("pname");
                for (String s : pn) {
                    for (String piece : s.split(",")) {
                        String q = piece.trim();
                        if (!q.isEmpty() && !names.contains(q)) names.add(q);
                    }
                }
            }
        } catch (Exception ignore) { }
        return names.toArray(new String[0]);
    }

    private static String resolveStudy(Model model, String want) {
        String[] tags = model.study().tags();
        if (want != null && !want.isEmpty()) {
            for (String t : tags) {
                if (t.equals(want)) return t;
            }
            System.err.println("模型里没有研究 '" + want + "'，可用: " + String.join(", ", tags));
            System.exit(2);
        }
        if (tags.length == 0) {
            System.err.println("模型里没有研究");
            System.exit(2);
        }
        return tags[0];
    }

    private static String firstDataset(Model model) {
        String[] ds = model.result().dataset().tags();
        if (ds.length == 0) {
            System.err.println("模型里没有数据集（研究可能没有求解）");
            System.exit(4);
        }
        return ds[0];
    }

    private static String[] split(String s) {
        if (s == null || s.trim().isEmpty()) return new String[0];
        return s.split("\\|", -1);
    }

    // 行 = 表达式，列 = 波长点；第一列若名为 *_nm 且表达式是 c_const/... 则换算成 nm
    private static void writeCsv(Path target, double[][] data, String[] expr, String[] cols) throws IOException {
        Path part = Paths.get(target.toString() + ".part");
        try (BufferedWriter w = Files.newBufferedWriter(part, StandardCharsets.UTF_8)) {
            w.write(String.join(",", cols));
            w.newLine();
            int nPoints = (data.length > 0) ? data[0].length : 0;
            for (int j = 0; j < nPoints; j++) {
                StringBuilder sb = new StringBuilder();
                for (int i = 0; i < data.length; i++) {
                    if (i > 0) sb.append(',');
                    double v = data[i][j];
                    if (i == 0 && cols[0].endsWith("_nm") && expr[0].trim().startsWith("c_const/")) {
                        // 表达式有时已按 nm 返回（866），有时是 m（8.66e-7），按量级判断
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

    private static void deleteTree(Path root) throws IOException {
        if (!Files.exists(root)) return;
        Files.walk(root)
             .sorted(Comparator.reverseOrder())
             .forEach(pth -> {
                 try { Files.deleteIfExists(pth); } catch (IOException ignore) { }
             });
    }
}
