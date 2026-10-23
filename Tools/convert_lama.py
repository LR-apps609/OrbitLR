# 2.9.7 · Converte LaMa (big-lama, Apache-2.0) in un modello Core ML per OrbitLR.
# Si esegue sul Mac di GitHub (workflow «Modello LaMa»): scarica il modello, lo converte, lo prova.
# Ingresso: image (1,3,S,S) valori 0…1, mask (1,1,S,S) 1 = da ricostruire. Uscita: output (1,3,S,S) 0…1.
import sys, numpy as np, torch, coremltools as ct

S = int(sys.argv[1]) if len(sys.argv) > 1 else 512
m = torch.jit.load("big-lama.pt", map_location="cpu").eval()

class Wrap(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m
    def forward(self, image, mask):
        out = self.m(image, mask)
        return torch.clamp(out, 0, 1)

w = Wrap(m).eval()
torch.manual_seed(0)
img = torch.rand(1, 3, S, S)
msk = torch.zeros(1, 1, S, S); msk[:, :, S//3:S//2, S//3:2*S//3] = 1
with torch.no_grad():
    ref = w(img, msk)
    traced = torch.jit.trace(w, (img, msk), check_trace=False)

mlm = ct.convert(
    traced,
    inputs=[ct.TensorType(name="image", shape=img.shape), ct.TensorType(name="mask", shape=msk.shape)],
    outputs=[ct.TensorType(name="output")],
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.macOS13,
    compute_precision=ct.precision.FLOAT32,
)
mlm.short_description = "LaMa (big-lama) per OrbitLR: ricostruisce le zone coperte da un logo"
mlm.license = "Apache-2.0 (LaMa, Samsung AI Center)"
mlm.save("LaMa.mlpackage")

pred = mlm.predict({"image": img.numpy(), "mask": msk.numpy()})["output"]
err = float(np.abs(pred - ref.numpy()).mean())
print(f"differenza media Core ML / PyTorch: {err:.5f}")
if err > 0.02:
    sys.exit("conversione non fedele")
