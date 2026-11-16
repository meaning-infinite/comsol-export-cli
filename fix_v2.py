import json, os, socket, subprocess, time

PORT = 2040
SERVER = r"D:\COMSOL\COMSOL64\Multiphysics\bin\win64\comsolmphserver.exe"
V2 = r"D:\COMSOL\COMSOL programs\03. Au_pad\models\Au_pad_LN_SiO2_v2_RF.mph"
OUT = r"D:\COMSOL\COMSOL programs\script\fix_v2.json"

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

# --- lumps ---
lp = c.physics("emw").feature("lport1")
for k, v in [("PortType", "UserDefined"), ("PortName", "1"), ("PortExcitation", "on"),
             ("TerminalType", "Cable"), ("Zref", "50[ohm]"), ("hPort", "10[um]"),
             ("wPort", "7[um]"), ("SourceType", "Voltage"), ("V0", "1[V]")]:
    try:
        lp.set(k, v)
    except Exception as e:
        rep["set_" + k] = "ERR " + str(e)[:120]
try:
    lp.set("ahPort", ["1", "0", "0"])
    rep["ahPort"] = [str(x) for x in list(lp.getStringArray("ahPort"))]
except Exception as e:
    rep["ahPort"] = "ERR " + str(e)[:200]
rep["lport"] = {}
for p in ["PortType", "PortName", "PortExcitation", "TerminalType", "Zref", "hPort", "wPort",
          "SourceType", "V0", "AdjustZref", "ElectricFieldDirection"]:
    try:
        rep["lport"][p] = str(lp.getString(p))
    except Exception:
        rep["lport"][p] = "n/a"

# --- probes ---
try:
    rep["probes"] = [str(t) for t in list(c.probe().tags())]
except Exception as e:
    rep["probes"] = "ERR " + str(e)[:150]
try:
    pr = c.probe().create("lport1_probe", "LumpedPort")
    rep["probe_created"] = str(pr.label())
except Exception as e:
    rep["probe_created"] = "ERR " + str(e)[:250]

# --- adaptive study step: align with HFSS Setup1 ---
f = J.study("std_adapt").feature("fdrfam")
for k, v in [("plist", "5[GHz]"), ("maxAdaptationNumber", "30"), ("dampingFactor", "0.05"),
             ("goalorientedtermination", "manual"),
             ("goalorientedterminationtolerance", "0.02"),
             ("goalorientedtolerancetype", "absolute"),
             ("savesolsref", "on")]:
    try:
        f.set(k, v)
    except Exception as e:
        rep["set_step_" + k] = "ERR " + str(e)[:150]
rep["rfadapt"] = {}
for p in ["plist", "maxAdaptationNumber", "dampingFactor", "errestandadap", "errestimerrest",
          "meshadaptmethod", "meshRefinement", "goalorientedtermination",
          "goalorientedterminationtolerance", "goalorientedtolerancetype", "savesolsref"]:
    try:
        rep["rfadapt"][p] = str(f.getString(p))
    except Exception:
        rep["rfadapt"][p] = "n/a"

# --- AWE step: output map back to whole physics ---
aw = J.study("std_sweep").feature("awe1")
for k, v in [("punit", "GHz"), ("plist", "range(0.001,1,8)"), ("rtol", "0.01"),
             ("sweeptype", "sparse"), ("preusesol", "auto")]:
    try:
        aw.set(k, v)
    except Exception as e:
        rep["set_awe_" + k] = "ERR " + str(e)[:150]
try:
    aw.setEntry("outputmap", "emw", "physics")
    rep["outputmap"] = str(aw.getString("outputmap"))
except Exception as e:
    rep["outputmap"] = "ERR " + str(e)[:200]
rep["awe"] = {p: (str(aw.getString(p)) if True else "") for p in ["punit", "plist", "rtol", "sweeptype", "preusesol"]}

try:
    rep["problems"] = [str(p.getMessage())[:150] for p in list(m.problems())]
except Exception as e:
    rep["problems"] = "ERR " + str(e)[:150]

m.save(V2)
rep["saved_size"] = os.path.getsize(V2)
jpath = os.path.splitext(V2)[0] + ".java"
m.save(V2)
if os.path.exists(jpath):
    os.remove(jpath)
m.save(jpath, "java")
m.save(V2)
rep["java_size"] = os.path.getsize(jpath)

with open(OUT, "w", encoding="utf-8") as fh:
    json.dump(rep, fh, ensure_ascii=False, indent=1)
print("WROTE", OUT)
