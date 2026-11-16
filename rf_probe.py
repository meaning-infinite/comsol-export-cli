import json, sys, traceback

rep = {}
out = r"D:\COMSOL\COMSOL programs\script\rf_probe_result.json"
try:
    import mph
    rep["mph"] = getattr(mph, "__version__", "?")
    cl = mph.Client(port=2040)
    rep["connected"] = True
    m = cl.create("probe_rf")
    J = getattr(m, "java", m)
    J.component().create("comp1", True)
    J.component("comp1").geom().create("geom1", 3)
    try:
        ph = J.component("comp1").physics().create("emw", "ElectromagneticWaves", "geom1")
        rep["emw"] = "OK"
        try:
            rep["emw_type"] = str(ph.getType())
        except Exception as e:
            rep["emw_type"] = "n/a"
        rep["emw_feats"] = [str(t) for t in list(ph.feature().tags())]
        try:
            lp = ph.feature().create("lport1", "LumpedPort", 2)
            rep["lport"] = "OK"
            rep["lport_props"] = [str(x) for x in list(lp.properties())]
            rep["lport_defaults"] = {}
            for k in ["PortType", "Zref", "hport", "wport", "PortExcitation", "TerminalType"]:
                try:
                    rep["lport_defaults"][k] = str(lp.getString(k))
                except Exception as e:
                    rep["lport_defaults"][k] = "ERR"
        except Exception as e:
            rep["lport"] = "ERR " + str(e)[:300]
    except Exception as e:
        rep["emw"] = "ERR " + str(e)[:500]
    try:
        J.study().create("std1")
        st = J.study("std1").feature().create("fdrfam", "FrequencyDomainRFAdaptiveMesh")
        rep["rfadapt"] = "OK"
        rep["rfadapt_props"] = [str(x) for x in list(st.properties())]
        rep["rfadapt_defaults"] = {}
        for k in ["maxAdaptationNumber", "tolerance", "dampingFactor", "plist", "goalorientedterminationexpression"]:
            try:
                rep["rfadapt_defaults"][k] = str(st.getString(k))
            except Exception:
                try:
                    rep["rfadapt_defaults"][k] = str(list(st.getStringArray(k)))
                except Exception as e2:
                    rep["rfadapt_defaults"][k] = "ERR"
    except Exception as e:
        rep["rfadapt"] = "ERR " + str(e)[:300]
except Exception as e:
    rep["fatal"] = str(e)[:800]
    rep["trace"] = traceback.format_exc()[-1200:]

with open(out, "w", encoding="utf-8") as f:
    json.dump(rep, f, ensure_ascii=False, indent=1)
print("WROTE", out)
