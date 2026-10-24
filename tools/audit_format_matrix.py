#!/usr/bin/env python3
"""Audit on-device 3-second capture results and saved final MOV headers.
No media decoding is inferred here: decodedFrames is produced by AVAssetReader on device.
"""
import argparse, collections, datetime, json, pathlib, re, struct

def atoms(data):
    pos=0
    while pos+8<=len(data):
        size,kind=struct.unpack_from('>I4s',data,pos); header=8
        if size==1: size=struct.unpack_from('>Q',data,pos+8)[0];header=16
        if size==0:size=len(data)-pos
        if size<header or pos+size>len(data):raise ValueError('Invalid MOV atom')
        yield kind,data[pos+header:pos+size]
        pos+=size

def audit(folder):
    plan=json.loads((folder/'plan.json').read_text());rows=[]
    for file in sorted(folder.glob('[0-9][0-9][0-9][0-9].json')):
        x=json.loads(file.read_text());r=x['request']; errors=[];missing=[];notes={}
        if x.get('error'):errors.append(x['error'])
        if x.get('captureError'):errors.append(x['captureError'])
        if not errors:
            for k in ('width','height','codec'):
                if x.get(k)!=r[k]:errors.append(f'{k} mismatch')
            if x.get('decodeStatus')!='completed' or x.get('decodedFrames')!=x.get('frames'): errors.append('decode incomplete')
            if not (2.8<=x.get('duration',0)<=4.5):errors.append('duration outside 3-second tolerance')
            if x.get('estimatedMissingFrames',0)>0:errors.append('missing video frames')
            if abs(x.get('averageFPS',0)-r['fps'])/r['fps']>.015: errors.append('FPS mismatch')
            if not x.get('audioTracks'): errors.append('audio absent')
            if not x.get('hasTelemetry'):errors.append('IMU absent')
            actual=x.get('actual',{})
            if actual.get('selectedColorSpace')!=r['color']:errors.append('active color mismatch')
            tags={m['id']:m['value'] for m in x.get('metadata',[])}
            for k in ['com.apple.quicktime.make','com.apple.quicktime.model','com.apple.quicktime.software','com.apple.quicktime.creationdate']:
                if 'mdta/'+k not in tags:missing.append(k)
            capture=tags.get('mdta/com.tinygrape.gyrocine.capture')
            if capture:
                snapshot=json.loads(capture);notes['captureSnapshot']=snapshot
                for field in ('model','lensName','lensType','position','colorSpace'):
                    if not snapshot.get(field):errors.append('capture snapshot missing '+field)
                for field in ('iso','aperture','exposureSeconds','whiteBalanceKelvin','zoom'):
                    if not isinstance(snapshot.get(field),(int,float)) or snapshot[field]<=0:errors.append('invalid capture '+field)
                if snapshot.get('scope')!='recordingStart':errors.append('capture snapshot scope missing')
                if snapshot.get('codec')!=r['codec']:errors.append('capture snapshot codec mismatch')
                if missing:errors.append('standard camera tags missing in new snapshot movie')
            desc='\n'.join(f for t in x.get('tracks',[]) if t['mediaType']=='vide' for f in t.get('formats',[]))
            notes['videoFormatFields']={k: v.strip().strip(chr(34)) for k,v in re.findall(r'(BitsPerComponent|CVImageBufferColorPrimaries|CVImageBufferTransferFunction|CVImageBufferLogTransferFunction|LogTransferFunction|CVImageBufferYCbCrMatrix) = ([^;]+);',desc)}
            audio=' '.join(f for t in x.get('tracks',[]) if t['mediaType']=='soun' for f in t.get('formats',[]))
            notes['audioFields']={k:v for k,v in re.findall(r'(mSampleRate|mChannelsPerFrame): ([0-9.]+)',audio)}
            if r['color'] in ('rec2020HDR','appleLog','appleLog2') and not re.search(r'BitsPerComponent = (10|12|16)',desc):errors.append('HDR/Log source file not tagged >=10-bit')
            expected={'rec709':'ITU_R_709_2','rec2020HDR':'ITU_R_2100_HLG','p3D65':'P3_D65','appleLog':'com.apple.rec2020.apple-log','appleLog2':'com.apple.apple-wide-gamut.apple-log'}[r['color']]
            # Apple Log tags use Apple-defined format extensions; report absence rather than infer a transform.
            notes['expectedColorMarker']=expected
            notes['colorMarkerFound']=expected in desc
            if expected not in desc:errors.append('color tag missing/mismatch')
            header=folder/(x['movie']+'.moov')
            if header.exists():
                moov=next(v for k,v in atoms(header.read_bytes()) if k==b'moov')
                mvhd=next(v for k,v in atoms(moov) if k==b'mvhd')
                creation=int.from_bytes(mvhd[4:12] if mvhd[0]==1 else mvhd[4:8],'big')
                notes['creationUTC']=(datetime.datetime(1904,1,1,tzinfo=datetime.timezone.utc)+datetime.timedelta(seconds=creation)).isoformat()
                if creation==0:errors.append('creation date unset')
                track_counts={}
                for k,trak in atoms(moov):
                    if k!=b'trak':continue
                    for k,mdia in atoms(trak):
                        if k!=b'mdia':continue
                        for k,minf in atoms(mdia):
                            if k!=b'minf':continue
                            for k,stbl in atoms(minf):
                                if k!=b'stbl':continue
                                tables=dict(atoms(stbl));stsd=tables.get(b'stsd',b'');stsz=tables.get(b'stsz',b'')
                                if len(stsd)>=16 and len(stsz)>=12:
                                    sample_codec=stsd[12:16].decode('ascii',errors='replace')
                                    track_counts[sample_codec]=int.from_bytes(stsz[8:12],'big')
                                    if sample_codec==r['codec'] and sample_codec.startswith('apc'):
                                        mdhd=next(v for k,v in atoms(mdia) if k==b'mdhd')
                                        timescale=int.from_bytes(mdhd[20:24] if mdhd[0]==1 else mdhd[12:16],'big')
                                        stts=tables.get(b'stts',b'');sample_index=0;gaps=[]
                                        for entry in range(int.from_bytes(stts[4:8],'big')):
                                            count,delta=struct.unpack_from('>II',stts,8+entry*8)
                                            if delta/timescale>1.5/r['fps'] and sample_index<x['frames']-1:
                                                gaps.append({'afterSample':sample_index,'count':count,'milliseconds':delta/timescale*1000})
                                            sample_index+=count
                                        notes['presentationGaps']=gaps
                notes['sampleCounts']=track_counts
                if track_counts.get(r['codec'])!=x['frames']:errors.append('MOV video sample count mismatch')
                if not any(track_counts.get(c)==x['frames'] for c in ('rtmd','gyrf')):errors.append('MOV telemetry sample count mismatch')
                payload=[v for k,b in atoms(moov) if k==b'udta' for tag,v in atoms(b) if tag==b'rmin']
                if payload:
                    n=json.loads(payload[-1]); notes['telemetryMetadata']=n
                    if n.get('intrinsic_frame_count')!=x['frames']:errors.append('K/video frame count mismatch')
                    for key in ('source_camera','lens_profile','intrinsic_mean','exposure_timing_model'):
                        if not n.get(key):errors.append('missing telemetry '+key)
                    notes['camera']=n.get('source_camera');notes['lens']=n.get('lens_profile',{}).get('lens_model')
                    if n.get('intrinsic_source')!='CameraIntrinsicMatrix':notes['estimatedK']=True
                else:errors.append('rmin metadata missing')
            else:errors.append('final MOV header missing')
        rows.append({'index':x['index'],'request':r,'movie':x.get('movie'),'pass':not errors,'errors':errors,'missingStandardTags':missing,'inspection':notes})
    summary={'planned':len(plan['cases']),'completed':len(rows),'pass':sum(r['pass'] for r in rows),
        'fail':sum(not r['pass'] for r in rows),'byEncoding':dict(collections.Counter(r['request']['encoding'] for r in rows)),
        'errors':dict(collections.Counter(e for r in rows for e in r['errors'])),
        'missingStandardTags':dict(collections.Counter(t for r in rows for t in r['missingStandardTags']))}
    return {'summary':summary,'cases':rows}
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('directory',type=pathlib.Path);p.add_argument('--output',type=pathlib.Path);args=p.parse_args()
    result=audit(args.directory)
    if args.output:args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(result['summary'],ensure_ascii=False,indent=2))
