"""Read MOV tables and GyroCine audit metadata without decoding or changing media."""
import json, struct, pathlib, sys, statistics

def boxes(data):
    p=0
    while p+8<=len(data):
        n,t=struct.unpack_from('>I4s',data,p); h=8
        if n==1:n=struct.unpack_from('>Q',data,p+8)[0];h=16
        if n==0:n=len(data)-p
        if n<h or p+n>len(data):raise ValueError('invalid atom')
        yield t.decode('latin1'),data[p+h:p+n]
        p+=n

def child(data,name):return next((v for k,v in boxes(data) if k==name),None)
def uint(d,p):return struct.unpack_from('>I',d,p)[0]
def summarize(path):
    path=pathlib.Path(path);out={'path':str(path),'bytes':path.stat().st_size}
    with path.open('rb') as f:
        p=0;moov=None
        while p<out['bytes']:
            f.seek(p);n,t=struct.unpack('>I4s',f.read(8));h=8
            if n==1:n=struct.unpack('>Q',f.read(8))[0];h=16
            if n==0:n=out['bytes']-p
            if t==b'moov':moov=f.read(n-h)
            p+=n
        if moov is None:raise ValueError('no moov')
        out['tracks']=[]
        for typ,tr in boxes(moov):
            if typ=='udta':
                note=child(tr,'rmin')
                if note:out['note']=json.loads(note)
            if typ!='trak':continue
            mdia=child(tr,'mdia');mdhd=child(mdia,'mdhd');scale=uint(mdhd,20 if mdhd[0]==1 else 12)
            handler=child(mdia,'hdlr')[8:12].decode('latin1');stbl=child(child(mdia,'minf'),'stbl')
            stts=child(stbl,'stts');runs=[struct.unpack_from('>II',stts,8+8*i) for i in range(uint(stts,4))]
            ds=[d/scale for n,d in runs for _ in range(n)]
            stsd=child(stbl,'stsd');codec=stsd[12:16].decode('latin1')
            r={'handler':handler,'codec':codec,'scale':scale,'samples':len(ds),'duration_seconds':sum(ds),'sample_interval_ms':{'min':min(ds)*1000,'median':statistics.median(ds)*1000,'max':max(ds)*1000},'stts_runs':runs,'has_ctts':child(stbl,'ctts') is not None,'has_edts':child(tr,'edts') is not None}
            edts=child(tr,'edts')
            if edts:
                el=child(edts,'elst')
                if el:
                    fmt='>Qqhh' if el[0]==1 else '>Iihh';step=struct.calcsize(fmt)
                    r['edit_list_raw']=[struct.unpack_from(fmt,el,8+step*i) for i in range(uint(el,4))]
            if handler=='meta':
                # Exporter writes one sample per chunk; verify that before reading packets.
                stsc=child(stbl,'stsc');r['stsc']=[struct.unpack_from('>III',stsc,8+12*i) for i in range(uint(stsc,4))]
                co=child(stbl,'co64');off=[struct.unpack_from('>Q',co,8+8*i)[0] for i in range(uint(co,4))] if co else []
                z=child(stbl,'stsz');sizes=[uint(z,4)]*uint(z,8) if uint(z,4) else [uint(z,12+4*i) for i in range(uint(z,8))]
                r['chunks']=len(off)
                if codec=='rtmd' and len(off)==len(sizes) and all(x[1]==1 for x in r['stsc']):
                    arrays={'gyro':[],'accel':[]};time=0
                    for i,(o,n) in enumerate(zip(off,sizes)):
                        f.seek(o);packet=f.read(n);tags={};q=28
                        while q+4<=len(packet):
                            k,l=struct.unpack_from('>HH',packet,q);q+=4;tags[k]=packet[q:q+l];q+=l
                        for key,base in [('gyro',0xe435),('accel',0xe445)]:
                            scale_v=struct.unpack('>f',tags[base+4])[0];v=tags[base+6];count=uint(v,0)
                            if count!=1:raise ValueError('expected one vector')
                            xyz=[v/scale_v for v in struct.unpack_from('>hhh',v,8)]
                            arrays[key].append([time,*xyz])
                        time+=ds[i]
                    r['imu_first']= {k:v[0] for k,v in arrays.items()};r['imu_last']={k:v[-1] for k,v in arrays.items()}
                    # Both Gyroflow Sony normalizers assign cumulative uniform times.
                    uniform=sum(ds)/len(ds);r['max_export_vs_uniform_time_error_us']=max(abs(v[0]-i*uniform) for i,v in enumerate(arrays['gyro']))*1e6
                    r['gyro_axis_rms_dps']=[(sum(x[j]**2 for x in arrays['gyro'])/len(ds))**.5 for j in [1,2,3]]
            out['tracks'].append(r)
    return out
if __name__=='__main__':print(json.dumps([summarize(p) for p in sys.argv[1:]],ensure_ascii=False,indent=2))
