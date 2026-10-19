import sys, array, math
def env(path, sr=8000, win=8):
    a = array.array('h'); a.frombytes(open(path,'rb').read())
    return [math.sqrt(sum(x*x for x in a[i:i+win])/win) for i in range(0, len(a)-win, win)], sr//win  # 1 ms per bin
def onsets(e, rate, rel=0.3, refractory_ms=500):
    srt = sorted(e); noise = srt[len(srt)//2]; peak = srt[int(len(srt)*0.999)]
    th = noise + rel*(peak-noise); out=[]; last=-1e9
    for i,v in enumerate(e):
        if v > th and i-last > refractory_ms:
            out.append(i/rate); last=i
    return out, noise, peak
e2,r = env(sys.argv[1]); e1,_ = env(sys.argv[2])
o2,n2,p2 = onsets(e2,r); o1,n1,p1 = onsets(e1,r)
print(f"2kHz(Mac) onsets: {len(o2)} noise={n2:.0f} peak={p2:.0f}; 1kHz(Hub) onsets: {len(o1)} noise={n1:.0f} peak={p1:.0f}")
d=[]
for t in o2:
    nxt=[u for u in o1 if 0 <= u-t < 0.9]
    if nxt: d.append((t,(nxt[0]-t)*1000))
for t,x in d: print(f"  mac {t:7.3f}s -> hub +{x:6.1f} ms")
xs=sorted(x for _,x in d)
if xs: print(f"N={len(xs)} median={xs[len(xs)//2]:.1f} ms min={xs[0]:.1f} max={xs[-1]:.1f} mean={sum(xs)/len(xs):.1f}")
print("hub onsets with no mac pair:", [round(u,3) for u in o1 if not any(0<=u-t<0.9 for t in o2)])
