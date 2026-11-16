import json, os, sys, traceback

V1 = r"D:\COMSOL\COMSOL programs\03. Au_pad\models\Au_pad_LN_SiO2_v1.mph"
V2 = r"D:\COMSOL\COMSOL programs\03. Au_pad\models\Au_pad_LN_SiO2_v2_RF.mph"
OUT = r"D:\COMSOL\COMSOL programs\script\convert_rf_log.json"

log = {}
def step(name, fn):
    try:
        r = fn()
        log[name] = "OK" if r is None else r
        return True
    except Exception as e:
        log[name] = "ERR " + str(e)[:400]
        return False

import socket, subprocess, time

PORT = 2040
SERVER = r"D:\COMSOL\COMSOL64\Multiphysics\bin\win64\comsolmphserver.exe"

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
log["server_up"] = server_up(PORT)

import mph
cl = mph.Client(port=PORT)
log["client"] = "connected"

# ---------- phase 0: probe allowed values on a scratch model ----------
def phase0():
    s = cl.create("probe_rf2")
    SJ = s.java
    SJ.component().create("comp1", True)
    SJ.component("comp1").geom().create("geom1", 3)
    SJ.component("comp1").geom("geom1").lengthUnit("mm")
    g = SJ.component("comp1").geom("geom1")
    g.create("blk1", "Block"); g.feature("blk1").set("size", ["2", "2", "0.1"]); g.run()
    ph = SJ.component("comp1").physics().create("emw", "ElectromagneticWaves", "geom1")
    res = {}
    # topology features available
    for tag, typ in [("pec_t", "PerfectElectricConductor"), ("scat_t", "Scattering"),
                     ("port_t", "Port"), ("lport_t", "LumpedPort"),
                     ("tbc_t", "TransitionBoundaryCondition"), ("pml_t", "PerfectlyMatchedLayer")]:
        try:
            ph.feature().create(tag, typ, 2)
            res[typ] = "OK"
        except Exception as e:
            res[typ] = "ERR " + str(e)[:120]
    res["emw_default_feats"] = [str(t) for t in list(ph.feature().tags())]
    # geometry level features (PML is a geometry-level feature)
    try:
        g.create("pml_t2", "PerfectlyMatchedLayer")
        res["geom_PML"] = "OK"
    except Exception as e:
        res["geom_PML"] = "ERR " + str(e)[:160]
    lp = ph.feature("lport_t")
    enums = {}
    for p in ["PortType", "TerminalType", "SourceType", "ElectricFieldDirection", "PortExcitation"]:
        try:
            enums[p] = [str(x) for x in list(lp.getAllowedPropertyValues(p))]
        except Exception as e:
            enums[p] = "ERR " + str(e)[:120]
    res["lport_enums"] = enums
    res["lport_defaults"] = {}
    for p in ["PortType", "TerminalType", "SourceType", "Zref", "hPort", "wPort", "V0", "I0", "P0",
              "ElectricFieldDirection", "AdjustZref", "PortExcitation", "PortName"]:
        try:
            res["lport_defaults"][p] = str(lp.getString(p))
        except Exception:
            res["lport_defaults"][p] = "n/a"
    # RF adaptive study step
    SJ.study().create("s1")
    st = SJ.study("s1").feature().create("fdrfam", "FrequencyDomainRFAdaptiveMesh")
    res["rfstep"] = {}
    for p in ["maxAdaptationNumber", "dampingFactor", "plist", "errestandadap",
              "goalorientedterminationtolerance", "goalorientedtolerancetype",
              "goalorientedtermination", "meshRefinement", "meshRefinementType",
              "stol", "usestol", "adaptionInGeometry", "enforceLinearElement", "errorEstType"]:
        try:
            res["rfstep"][p] = str(st.getString(p))
        except Exception as e:
            res["rfstep"][p] = "n/a"
    try:
        res["maxadapt_allowed"] = [str(x) for x in list(st.getAllowedPropertyValues("maxAdaptationNumber"))]
    except Exception as e:
        res["maxadapt_allowed"] = "ERR " + str(e)[:120]
    try:
        res["termination_allowed"] = [str(x) for x in list(st.getAllowedPropertyValues("goalorientedtermination"))]
    except Exception as e:
        res["termination_allowed"] = "ERR " + str(e)[:120]
    # AWE step with RF physics
    SJ.study().create("s2")
    aw = SJ.study("s2").feature().create("frawe", "FrequencyAdaptive")
    res["awe"] = {}
    for p in ["punit", "plist", "rtol", "sweeptype", "preusesol", "usertol"]:
        try:
            res["awe"][p] = str(aw.getString(p))
        except Exception as e:
            res["awe"][p] = "n/a"
    for p in ["outputmap", "outputselectionmap"]:
        try:
            res[p] = str(aw.getString(p))
        except Exception as e:
            res[p] = "ERR " + str(e)[:100]
    try:
        res["outputmap_entries"] = [str(x) for x in list(aw.getEntry("outputmap", "emw"))]
    except Exception as e:
        res["outputmap_entries"] = "ERR " + str(e)[:120]
    try:
        res["S11_expr_probe"] = str(ph.name())
    except Exception:
        pass
    cl.remove(s)
    return res

step("phase0_probe", phase0)

# ---------- phase 1: load v1 and convert ----------
m = cl.load(V1)
log["loaded"] = m.name()
J = m.java
c = J.component("comp1")

def convert():
    phs = [str(t) for t in list(c.physics().tags())]
    log["phys_before"] = phs
    if "ewfd" in phs:
        c.physics().remove("ewfd")
    ph = c.physics().create("emw", "ElectromagneticWaves", "geom1")
    ph.label("Electromagnetic Waves, Frequency Domain (RF, emw)")
    ph.selection().named("sel_ewfd_dom")
    log["emw_domains"] = [int(i) for i in list(ph.selection().entities())]
    return None
step("create_emw", convert)

def bounds():
    ph = c.physics("emw")
    r = {}
    pec = ph.create("pec_au", "PerfectElectricConductor", 2)
    pec.selection().named("sel_au_bnd")
    r["pec_faces"] = len(list(pec.selection().entities()))
    sc = ph.create("scat1", "Scattering", 2)
    sc.selection().named("sel_scat")
    r["scat_faces"] = len(list(sc.selection().entities()))
    try:
        r["scat_incident_default"] = str(sc.getString("IncidentField"))
    except Exception:
        pass
    lp = ph.create("lport1", "LumpedPort", 2)
    lp.selection().named("sel_port")
    lp.label("Lumped Port 1 (gap 10um, 50 ohm, HFSS S1)")
    r["lport_faces"] = len(list(lp.selection().entities()))
    return r
step("add_boundaries", bounds)

def port_settings():
    lp = c.physics("emw").feature("lport1")
    r = {}
    def setp(p, v):
        try:
            lp.set(p, v)
            r[p] = [str(lp.getString(p))]
        except Exception as e:
            r[p] = "ERR " + str(e)[:160]
    setp("PortName", "1")
    setp("PortExcitation", "on")
    setp("Zref", "50[ohm]")
    # try uniform port first (needs hPort/wPort)
    for pt in ["UserDefined", "Uniform"]:
        try:
            lp.set("PortType", pt)
            r["PortType"] = pt
            break
        except Exception as e:
            r["PortType_try_" + pt] = "ERR " + str(e)[:120]
    setp("hPort", "10[um]")
    setp("wPort", "7[um]")
    for p in ["PortType", "TerminalType", "SourceType", "Zref", "hPort", "wPort", "V0", "I0", "P0",
              "ElectricFieldDirection", "AdjustZref", "PortExcitation", "PortName"]:
        try:
            r[p] = str(lp.getString(p))
        except Exception:
            r.setdefault(p, "n/a")
    return r
step("port_settings", port_settings)

def studies():
    r = {}
    # adapt study: replace Frequency step with RF adaptive step
    st = J.study("std_adapt")
    st.label("01 adapt (5 GHz, RF adaptive mesh)")
    for t in list(st.feature().tags()):
        st.feature().remove(str(t))
    f = st.feature().create("fdrfam", "FrequencyDomainRFAdaptiveMesh")
    f.set("plist", "5[GHz]")
    f.set("maxAdaptationNumber", "20")
    f.set("dampingFactor", "0.05")
    for p, v in [("goalorientedterminationtolerance", "0.02"),
                 ("goalorientedtolerancetype", "relative")]:
        try:
            f.set(p, v)
            r[p] = str(f.getString(p))
        except Exception as e:
            r[p] = "ERR " + str(e)[:120]
    r["step_props"] = {p: str(f.getString(p)) for p in ["plist", "maxAdaptationNumber", "dampingFactor"]
                       if True}
    # sweep study: keep FrequencyAdaptive, retarget output map at emw
    aw = J.study("std_sweep").feature("awe1")
    try:
        aw.setEntry("outputmap", "emw", "selection")
        r["outputmap"] = "set"
    except Exception as e:
        r["outputmap"] = "ERR " + str(e)[:160]
    r["awe"] = {p: str(aw.getString(p)) for p in ["punit", "plist", "rtol", "sweeptype", "preusesol"]}
    return r
step("studies", studies)

def checks():
    r = {}
    r["problems"] = [(str(p.getMessage())[:120], str(p.getType())) for p in list(J.problems())]
    r["phys"] = [str(t) for t in list(c.physics().tags())]
    r["feats"] = [str(t) for t in list(c.physics("emw").feature().tags())]
    r["studies"] = [str(t) for t in list(J.study().tags())]
    r["steps"] = {str(t): [str(x) for x in list(J.study(t).feature().tags())] for t in list(J.study().tags())}
    return r
step("checks", checks)

def save():
    m.save(V2)
    return {"size": os.path.getsize(V2)}
step("save_v2", save)

# export java of v2
def exportj():
    jpath = os.path.splitext(V2)[0] + ".java"
    m.save(V2)
    if os.path.exists(jpath):
        os.remove(jpath)
    m.save(jpath, "java")
    m.save(V2)
    return {"java_size": os.path.getsize(jpath)}
step("export_java", exportj)

with open(OUT, "w", encoding="utf-8") as f:
    json.dump(log, f, ensure_ascii=False, indent=1)
print("WROTE", OUT)
