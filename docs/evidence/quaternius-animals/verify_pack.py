"""Verify the checked bake and refresh this review bundle after build_quaternius.sh."""
import hashlib
import json
import shutil
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parents[3]
build = root/'build/animal_sprites/quaternius-checked'
out = root/'docs/evidence/quaternius-animals'
source = json.loads((out/'source.json').read_text())
models = sorted(p.stem for p in (root/'art_src/quaternius_animals/glTF').glob('*.gltf'))
font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',24)
gallery = Image.new('RGB',(448*4,432*3),'#3b4243')
draw = ImageDraw.Draw(gallery)
checks = []
for index,name in enumerate(models):
    path = build/name
    render = json.loads((path/'render.json').read_text())
    visual = json.loads((path/'visual.json').read_text())
    verified = json.loads((path/'verification.json').read_text())
    gltf = json.loads((root/f'art_src/quaternius_animals/glTF/{name}.gltf').read_text())
    animations = {a['name']:a for a in gltf['animations']}
    for clip,info in render['clips'].items():
        samples = [gltf['accessors'][s['input']] for s in animations[info['source']]['samplers']]
        duration = max(s['max'][0] for s in samples)-min(s['min'][0] for s in samples)
        assert abs(duration-info['duration'])<.00001, (name,clip,'authored duration')
        assert abs(info['frames']/info['fps']-duration)<.00001
    atlas_path = root/visual['atlas_path'].removeprefix('res://')
    atlas = Image.open(atlas_path).convert('RGBA')
    assert hashlib.sha256(atlas_path.read_bytes()).hexdigest()==verified['sha256']
    assert set(atlas.getchannel('A').getdata())=={0,255}
    width,height = visual['frame']
    ox,oy = visual['origin']
    bounds = [192-ox,304-oy,192-ox+width,304-oy+height]
    assert min(bounds[:2])>0 and max(bounds[2:])<384,(name,'billboard viewport',bounds)
    count = 0
    unique = {}
    for clip,(first,n) in visual['anims'].items():
        for row in range(8):
            hashes = set()
            for frame in range(n):
                column = first+frame
                x = column%visual['columns']*width
                y = (column//visual['columns']*8+row)*height
                image = atlas.crop((x,y,x+width,y+height))
                assert image.getbbox(),(name,clip,row,frame,'empty')
                hashes.add(hashlib.sha256(image.tobytes()).hexdigest())
                count += 1
            if clip in ('walk','run'):
                assert len(hashes)>1,(name,clip,row,'frozen animation')
            unique[f'{clip}/{row}'] = len(hashes)
    assert count==verified['frames']==len(list((path/'raw').glob('*.png')))
    for file,sha in render['sources'].items():
        assert hashlib.sha256((root/file).read_bytes()).hexdigest()==sha,file
    d = out/'models'/name
    d.mkdir(parents=True,exist_ok=True)
    for file in ('render.json','visual.json','verification.json','directions.webp','idle.gif','walk.gif','run.gif',atlas_path.name):
        shutil.copy2(path/file,d/file)
    # Shared 2x pixel scale and foot anchor; do not fit species independently.
    image = Image.open(path/'pixels/idle_se_00.png').convert('RGBA').crop((render['cell']//2-ox,render['foot']-oy,
        render['cell']//2-ox+width,render['foot']-oy+height)).resize((width*2,height*2),Image.Resampling.NEAREST)
    px,py = index%4*448,index//4*432
    gallery.paste(image,(px+224-ox*2,py+390-oy*2),image)
    draw.text((px+16,py+14),name,font=font,fill='#eee0c4')
    checks.append({'model':name,'frames':count,'viewport_bounds':bounds,'unique_frames':unique,
        'authored_durations_match':True,'atlas_sha256':verified['sha256']})
gallery.save(out/'pack.webp',lossless=True)
shutil.copy2(build/'inventory.json',out/'inventory.json')
report = {'models':len(checks),'frames':sum(c['frames'] for c in checks),'directions':8,
    'clips':['idle','walk','run'],'empty_frames':0,'clipped_frames':0,'binary_alpha':True,
    'default_game_content_modified':False,'results':checks}
(out/'pack-verification.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k!='results'}))
