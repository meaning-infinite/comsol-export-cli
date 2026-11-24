import com.comsol.model.*;
import java.lang.reflect.Proxy;
import java.nio.file.*;
import java.util.*;
import java.util.function.BiFunction;

/** Small contract tests. No COMSOL session or model files are opened. */
public class ExportContractTest {
    static void check(boolean ok, String label) {
        if (!ok) throw new AssertionError(label);
        System.out.println("PASS " + label);
    }

    static <T> T stub(Class<T> type, BiFunction<String,Object[],Object> query) {
        return type.cast(Proxy.newProxyInstance(type.getClassLoader(), new Class<?>[]{type},
                (proxy, method, args) -> query.apply(method.getName(), args == null ? new Object[0] : args)));
    }

    static StudyFeature step(String tag, boolean eigenOnly) {
        return stub(StudyFeature.class, (name, a) -> {
            if (name.equals("isActive")) return tag.equals(eigenOnly ? "eig" : "wave");
            if (name.equals("getType")) return tag.equals("wave") ? "Wavelength" : "Eigenfrequency";
            throw new UnsupportedOperationException(name);
        });
    }

    static SolverSequence sol(String tag) {
        return stub(SolverSequence.class, (name, a) -> {
            switch (name) {
                case "study": return tag.equals("other") ? "std2" : "std1";
                case "getType": return tag.equals("oldStore") ? "Eigenvalue" : "Stationary";
                case "isEmpty": return tag.equals("empty");
                case "getSize": return new int[]{12,2};
                case "feature":
                    if (a.length == 0) return stub(SolverFeatureList.class, (n,b) ->
                            tag.equals("oldStore") ? new String[0] : new String[]{"step"});
                    return stub(SolverFeature.class, (n,b) -> n.equals("getType") ? "StudyStep" :
                            (tag.equals("disabled") ? "eig" : "wave"));
                default: throw new UnsupportedOperationException(name);
            }
        });
    }

    static Model model(boolean eigenOnly) {
        String[] tags = {"active","disabled","other","oldStore","empty"};
        Study st = stub(Study.class, (name, a) -> {
            if (name.equals("getSolverSequences")) return new String[]{"active","disabled","oldStore","empty"};
            if (name.equals("feature") && a.length == 0) return stub(StudyFeatureList.class, (n,b) -> new String[]{"wave","eig"});
            return step((String)a[0], eigenOnly);
        });
        return stub(Model.class, (name, a) -> {
            if (name.equals("study")) return st;
            if (name.equals("sol") && a.length == 0) return stub(SolverSequenceList.class, (n,b) -> tags);
            return sol((String)a[0]);
        });
    }

    public static void main(String[] args) throws Exception {
        ExportDriver.Job j = new ExportDriver.Job();
        j.p = new LinkedHashMap<>();
        j.model = model(false);
        j.study = "std1";
        j.sols = ExportDriver.listSols(j);
        check(j.sols.size() == 1 && j.sols.get(0).tag.equals("active"), "study excludes disabled, foreign and empty solutions");
        check(!ExportDriver.activeSequence(model(true),"std1","active"), "disabled wave sequence is excluded when eigenfrequency is enabled");
        j.p.put("solscope","all");
        j.sols = ExportDriver.listSols(j);
        check(j.sols.size()==4 && j.sols.get(2).study.equals("std2"), "explicit all includes other studies, excludes empty solutions");
        check(Arrays.equals(ExportDriver.pickSol(j,"5"),new String[]{"other","1"}), "global field index maps to the correct local solution");
        check(Double.isNaN(ExportDriver.normalizedAbsorption(3,0)) && ExportDriver.normalizedAbsorption(0.25,1)==25,
              "zero incident power yields undefined percentage");
        j.outdir=Files.createTempDirectory("TEMP_comsol_contract_");
        try {
            Path file=j.outdir.resolve("rows.csv");
            try (ExportDriver.CsvStream csv=new ExportDriver.CsvStream(j,file,new String[]{"value","Pin_W","A_pct","lambda_nm"})) {
                double[] row={1.000000000000001,0,Double.NaN,866.000000000001};
                csv.row(row,j.sols.get(0),1,new double[0],0);
                csv.row(row,j.sols.get(2),2,new double[0],0);
                csv.commit();
            }
            List<String> lines=Files.readAllLines(file);
            check(lines.size()==3 && lines.get(1).contains("1.000000000000001,0.0,,866.000000000001") &&
                  lines.get(2).endsWith("std2,other,2,6"), "duplicate values retain precision, undefined percentage and original IDs across gaps");
            boolean rejected=false;
            try { ExportDriver.requireNoLoss(j,1,1); } catch (IllegalStateException expected) { rejected=true; }
            check(rejected,"nonfinite rows fail by default");
            j.p.put("block.1.allownan","1");
            ExportDriver.requireNoLoss(j,1,1);
            check(!j.details.isEmpty(),"explicit Allownan records omitted count");
            j.blocks=1; j.outname="test";
            j.p.put("block.1.type","eigenslice"); j.p.put("block.1.maxmodes","1"); j.p.put("block.1.planes","xy|yz");
            ExportDriver.planArtifacts(j);
            check(j.expected.size()==8, "every requested mode and plane is accounted for");
            j.jobDir=j.outdir;
            j.p.put("resultdir",j.outdir.toString());
            Path first=j.expected.iterator().next();
            Files.write(first,new byte[]{1});
            ExportDriver.record(j,first,"first completed plane");
            ExportDriver.writeManifest(j,4,"slice interrupted");
            String report=Files.readString(j.outdir.resolve("EXPORT_MANIFEST.md"));
            check(report.lines().filter(line -> line.startsWith("- 缺件 ")).count()==7 &&
                  report.contains("first completed plane"), "partial slice block reports completed plane and all seven missing files");
        } finally { ExportDriver.deleteTree(j.outdir); }
    }
}
