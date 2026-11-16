import json, os, socket, subprocess, time

PORT = 2040
SERVER = r"D:\COMSOL\COMSOL64\Multiphysics\bin\win64\comsolmphserver.exe"
V2 = r"D:\COMSOL\COMSOL programs\03. Au_pad\models\Au_pad_LN_SiO2_v2_RF.mph"
OUT = r"D:\COMSOL\COMSOL programs\script\verify_v2.json"

def server_up(port):
    s = socket.socket(); s.settimeout(1)
    try:
        s.connect(("127.0.0.1", port)); s.close(); return True
    except Exception:
        s.close(); return False

if not server_up(PORT):
    subprocess.Popen([SERVER, "-port", str(PORT), "-silent"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     cwd=os.path.dirname(os.path.abspath(__file__)))
    for _ in range(180):
        if server_up(PORT):
            break
        time.sleep(1)

import mph
cl = mph.Client(port=PORT)
m = cl.load(V2)
J = m.java
c = J.component("comp1")
rep = {}
rep["name"] = m.name()
try:
    rep["problems"] = [(str(p.getMessage())[:160], str(p.getType())) for p in list(m.problems())]
except Exception as e:
    rep["problems"] = "ERR " + str(e)[:200]
rep["physics"] = [str(t) for t in list(c.physics().tags())]
ph = c.physics("emw")
rep["feats"] = [str(t) for t in list(ph.feature().tags())]
rep["domains"] = [int(i) for i in list(ph.selection().entities())]
for t in ["pec_au", "scat1", "lport1"]:
    rep[t] = [int(i) for i in list(ph.feature(t).selection().entities())]
lp = ph.feature("lport1")
rep["lport"] = {}
for p in ["PortName", "PortType", "PortExcitation", "Zref", "hPort", "wPort", "TerminalType",
          "SourceType", "V0", "P0", "AdjustZref", "ElectricFieldDirection"]:
    try:
        rep["lport"][p] = str(lp.getString(p))
    except Exception:
        rep["lport"][p] = "n/a"
rep["studies"] = {}
for t in [str(x) for x in list(J.study().tags())]:
    st = J.study(t)
    rep["studies"][t] = {"label": str(st.label()),
                         "steps": [(str(s), str(st.feature(s).getType())) for s in [str(x) for x in list(st.feature().tags())]]}
f = J.study("std_adapt").feature("fdrfam")
rep["rfadapt"] = {}
for p in ["plist", "maxAdaptationNumber", "dampingFactor", "errestandadap", "errestimerrest",
          "meshRefinement", "meshRefinementType", "goalorientedtermination",
          "goalorientedterminationtolerance", "goalorientedtolerancetype", "savesolsref",
          "meshadaptmethod", "goalngenAUX", "goaluserngen", "enforceLinearElement"]:
    try:
        rep["rfadapt"][p] = str(f.getString(p))
    except Exception:
        rep["rfadapt"][p] = "n/a"
aw = J.study("std_sweep").feature("awe1")
rep["awe"] = {}
for p in ["punit", "plist", "rtol", "sweeptype", "preusesol", "usertol", "outputmap"]:
    try:
        rep["awe"][p] = str(aw.getString(p))
    except Exception:
        rep["awe"][p] = "n/a"
rep["materials"] = [(str(t), str(c.material(t).label())) for t in [str(x) for x in list(c.material().tags())]]
rep["mesh"] = [(str(t), str(c.mesh("mesh1").feature(t).getType())) for t in [str(x) for x in list(c.mesh("mesh1").feature().tags())]]
rep["hauto"] = str(c.mesh("mesh1").feature("size").getString("hauto"))
rep["geom"] = {"dom": int(c.geom("geom1").getNDomains()), "bnd": int(c.geom("geom1").getNBoundaries())}
with open(OUT, "w", encoding="utf-8") as fh:
    json.dump(rep, fh, ensure_ascii=False, indent=1)
print("WROTE", OUT)
