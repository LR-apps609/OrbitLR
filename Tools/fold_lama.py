# OrbitLR per Windows · rende LaMa (ONNX) apribile da tract: con la misura fissa (1×3×512×512),
# tutto ciò che dipende solo dalle misure (Shape → Range → Cos/Sin: le matrici della trasformata di Fourier)
# diventa una costante, calcolata una volta con onnxruntime. Il resto del modello non cambia.
# Uso: python fold_lama.py ingresso.onnx uscita.onnx
import sys, collections
import numpy as np, onnx, onnxruntime as ort
from onnx import helper, numpy_helper

src, dst = sys.argv[1], sys.argv[2]
m = onnx.load(src)
g = m.graph
S = 512
shapes = {"image": [1, 3, S, S], "mask": [1, 1, S, S]}
for i in g.input:
    if i.name in shapes:
        for d, v in zip(i.type.tensor_type.shape.dim, shapes[i.name]):
            d.ClearField("dim_param"); d.dim_value = v

inputs = {i.name for i in g.input} - {t.name for t in g.initializer}
dep = set(inputs)  # tensori che dipendono dalla foto
for n in g.node:   # l'ordine dei nodi in ONNX è già topologico
    if n.op_type == "Shape":
        continue   # la misura è fissa: non dipende dai valori
    if any(x in dep for x in n.input if x):
        dep.update(o for o in n.output if o)

# Le costanti usate da nodi che dipendono dalla foto (e non sono già costanti del modello)
init_names = {t.name for t in g.initializer}
const_out = {o for n in g.node if n.op_type == "Constant" for o in n.output}
need = []
for n in g.node:
    if any(x in dep for x in n.input if x) or n.op_type == "Shape":
        for x in n.input:
            if x and x not in dep and x not in init_names and x not in const_out and x not in need:
                need.append(x)
print("tensori da calcolare:", len(need))

# Calcolo con onnxruntime: si espongono come uscite
m2 = onnx.ModelProto(); m2.CopyFrom(m)
for x in need:
    m2.graph.output.append(helper.ValueInfoProto(name=x))
so = ort.SessionOptions(); so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
sess = ort.InferenceSession(m2.SerializeToString(), so, providers=["CPUExecutionProvider"])
feeds = {"image": np.random.rand(1, 3, S, S).astype(np.float32), "mask": np.zeros((1, 1, S, S), np.float32)}
names = [o.name for o in sess.get_outputs()]
vals = dict(zip(names, sess.run(None, feeds)))

# Nuovo grafo: i nodi che dipendono dalla foto, con le costanti al posto dei calcoli sulle misure
for x in need:
    g.initializer.append(numpy_helper.from_array(np.asarray(vals[x]), name=x))
keep = [n for n in g.node if any(x in dep for x in n.input if x)]
# Le costanti del modello ancora usate
used = {x for n in keep for x in n.input} | {o.name for o in g.output}
keep_consts = [n for n in g.node if n.op_type == "Constant" and any(o in used for o in n.output)]
del g.node[:]
g.node.extend(keep_consts + keep)
alive = {x for n in g.node for x in n.input} | {o.name for o in g.output}
live_init = [t for t in g.initializer if t.name in alive]
del g.initializer[:]
g.initializer.extend(live_init)
del g.value_info[:]

# Einsum → Transpose + Reshape + MatMul (tract non compila alcuni Einsum). Le misure si leggono da un'esecuzione.
eins = [n for n in g.node if n.op_type == "Einsum"]
m3 = onnx.ModelProto(); m3.CopyFrom(m)
probe = sorted({x for n in eins for x in n.input})
for x in probe:
    m3.graph.output.append(helper.ValueInfoProto(name=x))
s3 = ort.InferenceSession(m3.SerializeToString(), so, providers=["CPUExecutionProvider"])
shp = {o.name: v.shape for o, v in zip(s3.get_outputs(), s3.run(None, feeds))}
eqs = collections.Counter(helper.get_node_attr_value(n, "equation").decode() if isinstance(helper.get_node_attr_value(n, "equation"), bytes) else helper.get_node_attr_value(n, "equation") for n in eins)
print("Einsum:", dict(eqs))
cnt = [0]
def const(arr):
    cnt[0] += 1
    name = f"orbit_c{cnt[0]}"
    g.initializer.append(numpy_helper.from_array(np.asarray(arr, dtype=np.int64), name=name))
    return name
new_nodes = []
for n in g.node:
    if n.op_type != "Einsum":
        new_nodes.append(n); continue
    eq = helper.get_node_attr_value(n, "equation")
    eq = eq.decode() if isinstance(eq, bytes) else eq
    lhs, out = eq.replace(" ", "").split("->")
    a, b = lhs.split(",")
    A, B = n.input
    sa, sb = shp[A], shp[B]
    dim = {}
    for ch, d in list(zip(a, sa)) + list(zip(b, sb)):
        assert dim.get(ch, d) == d, (eq, sa, sb)
        dim[ch] = d
    assert len(set(a)) == len(a) and len(set(b)) == len(b) and set(out) <= set(a) | set(b), eq
    assert all(c in b or c in out for c in a) and all(c in a or c in out for c in b), eq
    bat = [c for c in out if c in a and c in b]
    con = [c for c in a if c in b and c not in out]
    lef = [c for c in a if c not in b]
    rig = [c for c in b if c not in a]
    pfx = n.output[0] + "_orbit"
    ta = [a.index(c) for c in bat + lef + con]
    tb = [b.index(c) for c in bat + con + rig]
    P = lambda cs: int(np.prod([dim[c] for c in cs])) if cs else 1
    new_nodes.append(helper.make_node("Transpose", [A], [pfx + "_ta"], perm=ta))
    new_nodes.append(helper.make_node("Reshape", [pfx + "_ta", const([P(bat), P(lef), P(con)])], [pfx + "_ra"]))
    new_nodes.append(helper.make_node("Transpose", [B], [pfx + "_tb"], perm=tb))
    new_nodes.append(helper.make_node("Reshape", [pfx + "_tb", const([P(bat), P(con), P(rig)])], [pfx + "_rb"]))
    new_nodes.append(helper.make_node("MatMul", [pfx + "_ra", pfx + "_rb"], [pfx + "_mm"]))
    mid = bat + lef + rig
    new_nodes.append(helper.make_node("Reshape", [pfx + "_mm", const([dim[c] for c in mid])], [pfx + "_rs"]))
    new_nodes.append(helper.make_node("Transpose", [pfx + "_rs"], [n.output[0]], perm=[mid.index(c) for c in out]))
del g.node[:]
g.node.extend(new_nodes)
onnx.save(m, dst)

# Prova: stesso risultato del modello originale
a = ort.InferenceSession(src, providers=["CPUExecutionProvider"]).run(None, feeds)[0]
b = ort.InferenceSession(dst, providers=["CPUExecutionProvider"]).run(None, feeds)[0]
print("differenza massima con l'originale:", float(np.abs(a - b).max()), "valori", float(b.min()), float(b.max()))
print(sorted(collections.Counter(n.op_type for n in g.node).items(), key=lambda x: -x[1]))
assert np.abs(a - b).max() < 1e-3
