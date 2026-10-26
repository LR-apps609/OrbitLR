# OrbitLR per Windows · rende LaMa (ONNX) apribile da tract: con la misura fissa (1×3×512×512),
# tutto ciò che dipende solo dalle misure (Shape → Range → Cos/Sin: le matrici della trasformata di Fourier)
# diventa una costante, calcolata una volta con onnxruntime. Il resto del modello non cambia.
# Uso: python fold_lama.py ingresso.onnx uscita.onnx
import sys, collections
import numpy as np, onnx, onnxruntime as ort
from onnx import helper, numpy_helper


def run_outputs(model, names, feeds, values=True, chunk=40):
    """Calcola alcuni tensori intermedi a gruppi (poca memoria). values=False: solo le misure."""
    out = {}
    names = list(names)
    for i in range(0, len(names), chunk):
        part = names[i:i + chunk]
        mm = onnx.ModelProto(); mm.CopyFrom(model)
        del mm.graph.output[:]
        for x in part:
            mm.graph.output.append(helper.ValueInfoProto(name=x))
        so_ = ort.SessionOptions(); so_.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
        sess_ = ort.InferenceSession(mm.SerializeToString(), so_, providers=["CPUExecutionProvider"])
        for o, v in zip(sess_.get_outputs(), sess_.run(None, feeds)):
            out[o.name] = np.asarray(v) if values else v.shape
        del sess_, mm
    return out

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

# Calcolo con onnxruntime, a gruppi
so = ort.SessionOptions(); so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
feeds = {"image": np.random.rand(1, 3, S, S).astype(np.float32), "mask": np.zeros((1, 1, S, S), np.float32)}
vals = run_outputs(m, need, feeds)

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
shp = run_outputs(m, sorted({x for n in eins for x in n.input}), feeds, values=False)
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
    new_nodes.append(helper.make_node("Reshape", [pfx + "_ta", const(([P(bat)] if bat else []) + [P(lef), P(con)])], [pfx + "_ra"]))
    new_nodes.append(helper.make_node("Transpose", [B], [pfx + "_tb"], perm=tb))
    new_nodes.append(helper.make_node("Reshape", [pfx + "_tb", const(([P(bat)] if bat else []) + [P(con), P(rig)])], [pfx + "_rb"]))
    new_nodes.append(helper.make_node("MatMul", [pfx + "_ra", pfx + "_rb"], [pfx + "_mm"]))
    mid = bat + lef + rig
    new_nodes.append(helper.make_node("Reshape", [pfx + "_mm", const([dim[c] for c in mid])], [pfx + "_rs"]))
    new_nodes.append(helper.make_node("Transpose", [pfx + "_rs"], [n.output[0]], perm=[mid.index(c) for c in out]))
del g.node[:]
g.node.extend(new_nodes)

# MatMul a più dimensioni con una matrice costante 2D → MatMul 2D (tract compila male alcuni MatMul con «batch»)
consts = {t.name: numpy_helper.to_array(t) for t in g.initializer}
mms = [n for n in g.node if n.op_type == "MatMul"]
shp4 = run_outputs(m, sorted({x for n in mms for x in n.input if x not in consts}), feeds, values=False)
shape_of = lambda x: consts[x].shape if x in consts else shp4[x]
pat = collections.Counter((len(shape_of(n.input[0])), len(shape_of(n.input[1])), n.input[0] in consts, n.input[1] in consts) for n in mms)
print("MatMul (rango A, rango B, A costante, B costante):", dict(pat))
out_nodes = []
for n in g.node:
    if n.op_type != "MatMul":
        out_nodes.append(n); continue
    A, B = n.input
    sa, sb = shape_of(A), shape_of(B)
    pfx = n.output[0] + "_orbit2"
    if len(sb) == 2 and len(sa) > 2:
        # [..., M, K] · [K, N] → reshape [prod, K] · [K, N] → [..., M, N]
        out_nodes.append(helper.make_node("Reshape", [A, const([-1, sa[-1]])], [pfx + "_a"]))
        out_nodes.append(helper.make_node("MatMul", [pfx + "_a", B], [pfx + "_m"]))
        out_nodes.append(helper.make_node("Reshape", [pfx + "_m", const(list(sa[:-1]) + [sb[-1]])], [n.output[0]]))
    elif len(sa) == 2 and len(sb) > 2:
        # [M, K] · [..., K, N] = ([..., N, K] · [K, M])ᵀ
        r = len(sb)
        perm = list(range(r - 2)) + [r - 1, r - 2]
        out_nodes.append(helper.make_node("Transpose", [B], [pfx + "_bt"], perm=perm))
        out_nodes.append(helper.make_node("Reshape", [pfx + "_bt", const([-1, sb[-2]])], [pfx + "_b"]))
        out_nodes.append(helper.make_node("Transpose", [A], [pfx + "_at"], perm=[1, 0]))
        out_nodes.append(helper.make_node("MatMul", [pfx + "_b", pfx + "_at"], [pfx + "_m"]))
        out_nodes.append(helper.make_node("Reshape", [pfx + "_m", const(list(sb[:-2]) + [sb[-1], sa[0]])], [pfx + "_r"]))
        out_nodes.append(helper.make_node("Transpose", [pfx + "_r"], [n.output[0]], perm=perm))
    elif len(sa) > 2 and len(sb) > 2 and tuple(sa[:-2]) == tuple(sb[:-2]) and int(np.prod(sa[:-2])) == 1:
        # batch di 1: [M, K] · [K, N]
        out_nodes.append(helper.make_node("Reshape", [A, const([sa[-2], sa[-1]])], [pfx + "_a"]))
        out_nodes.append(helper.make_node("Reshape", [B, const([sb[-2], sb[-1]])], [pfx + "_b"]))
        out_nodes.append(helper.make_node("MatMul", [pfx + "_a", pfx + "_b"], [pfx + "_m"]))
        out_nodes.append(helper.make_node("Reshape", [pfx + "_m", const(list(sa[:-1]) + [sb[-1]])], [n.output[0]]))
    elif len(sa) > 2 and len(sb) > 2 and tuple(sa[:-2]) == tuple(sb[:-2]):
        # batch uguali: [B, M, K] · [B, K, N]
        bat = int(np.prod(sa[:-2]))
        out_nodes.append(helper.make_node("Reshape", [A, const([bat, sa[-2], sa[-1]])], [pfx + "_a"]))
        out_nodes.append(helper.make_node("Reshape", [B, const([bat, sb[-2], sb[-1]])], [pfx + "_b"]))
        out_nodes.append(helper.make_node("MatMul", [pfx + "_a", pfx + "_b"], [pfx + "_m"]))
        out_nodes.append(helper.make_node("Reshape", [pfx + "_m", const(list(sa[:-1]) + [sb[-1]])], [n.output[0]]))
    else:
        out_nodes.append(n)
del g.node[:]
g.node.extend(out_nodes)
onnx.save(m, dst)

# Prova: stesso risultato del modello originale
a = ort.InferenceSession(src, providers=["CPUExecutionProvider"]).run(None, feeds)[0]
b = ort.InferenceSession(dst, providers=["CPUExecutionProvider"]).run(None, feeds)[0]
print("differenza massima con l'originale:", float(np.abs(a - b).max()), "valori", float(b.min()), float(b.max()))
print(sorted(collections.Counter(n.op_type for n in g.node).items(), key=lambda x: -x[1]))
assert np.abs(a - b).max() <= 1e-4 * max(1.0, float(np.abs(a).max())), "il modello cambiato non dà lo stesso risultato"
