"""Reduce and pack a horse candidate without modifying game content.

python3 tools/art/animal_sprites/export.py build/animal_sprites/horse-v1
Writes a RoSprite-compatible visual, eight-direction review and motion GIFs.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path.insert(0, str(HERE.parent / "ro_sprites"))
from pixelate import outline, reduce, reduce_depth, fill_depth


def reduce_frame(image,scale):
    """The RO majority-colour rule, batched over opaque blocks instead of pixels."""
    rgba = np.asarray(image.convert("RGBA"),dtype=np.uint8)
    height,width = rgba.shape[0]//scale,rgba.shape[1]//scale
    blocks = rgba[:height*scale,:width*scale].reshape(height,scale,width,scale,4).transpose(0,2,1,3,4).reshape(height,width,-1,4)
    opaque = blocks[...,3]>=128
    cover = opaque.mean(axis=2)>=.5
    chosen = blocks[cover]
    keys = (chosen[...,0].astype(np.int64)<<16)|(chosen[...,1].astype(np.int64)<<8)|chosen[...,2]
    keys = np.sort(np.where(opaque[cover],keys,1<<24),axis=1)
    counts = (keys[:,:,None]==keys[:,None,:]).sum(axis=2)
    counts[keys==(1<<24)] = 0
    colour = keys[np.arange(len(keys)),counts.argmax(axis=1)]
    output = np.zeros((height,width,4),np.uint8)
    output[cover] = np.stack((colour>>16,(colour>>8)&255,colour&255,np.full_like(colour,255)),axis=1)
    return output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("build", type=Path)
    args = parser.parse_args()
    path = args.build.resolve()
    report = json.loads((path/"render.json").read_text())
    species = report.get("species","horse")
    for source, expected in report["sources"].items():
        if hashlib.sha256((ROOT/source).read_bytes()).hexdigest() != expected:
            raise ValueError(f"Rendered source changed: {source}")
    pixels = path/"pixels"
    pixels.mkdir(exist_ok=True)
    pictures = {}
    volumes = {}
    bounds = []
    for clip, info in report["clips"].items():
        for row, direction in enumerate(report["directions"]):
            for i in range(info["frames"]):
                name = f"{clip}_{direction}_{i:02d}.png"
                image = Image.fromarray(outline(reduce_frame(Image.open(path/"raw"/name),report["scale"])))
                box = image.getbbox()
                if box is None or box[0]==0 or box[1]==0 or box[2]==image.width or box[3]==image.height:
                    raise ValueError(f"Empty or clipped frame: {name}")
                image.save(pixels/name)
                pictures[clip,row,i] = image
                if "volume" in report:
                    solid = np.asarray(image)[...,3]>0
                    depth = fill_depth(reduce_depth(Image.open(path/"raw"/name.replace(".png",".volume.png")),report["cell"]),solid)
                    if np.any(depth[solid]==0):
                        raise ValueError(f"Missing animal volume: {name}")
                    rgba = np.zeros((*depth.shape,4),dtype=np.uint8)
                    rgba[...,0],rgba[...,1],rgba[...,3] = depth>>8,depth&255,np.where(solid,255,0)
                    volumes[clip,row,i] = Image.fromarray(rgba)
                bounds.append(box)
    left, top = min(b[0] for b in bounds), min(b[1] for b in bounds)
    right, bottom = max(b[2] for b in bounds), max(b[3] for b in bounds)
    width, height = right-left, bottom-top
    frame_count = sum(c["frames"] for c in report["clips"].values())
    columns = min(frame_count,4096//width)
    atlas = Image.new("RGBA",(columns*width,8*((frame_count+columns-1)//columns)*height))
    volume_atlas = Image.new("RGBA",atlas.size) if volumes else None
    anims = {}
    column = 0
    for clip, info in report["clips"].items():
        anims[clip] = [column,info["frames"]]
        for i in range(info["frames"]):
            for row in range(8):
                atlas.paste(pictures[clip,row,i].crop((left,top,right,bottom)),
                    ((column%columns)*width,((column//columns)*8+row)*height))
                if volume_atlas:
                    volume_atlas.paste(volumes[clip,row,i].crop((left,top,right,bottom)),
                        ((column%columns)*width,((column//columns)*8+row)*height))
            column += 1
    atlas_path = path/f"{species}.png"
    atlas.save(atlas_path,optimize=True)
    relative = atlas_path.relative_to(ROOT).as_posix()
    visual = {"format":"ro","mode":"character","animal":True,"atlas":atlas_path.name,"atlas_path":"res://"+relative,
        "pixel_scale":.25,"key":species,"frame":[width,height],"rect":[0,0,width,height],
        "origin":[report["cell"]//2-left, report["foot"]-top],"columns":columns,"anims":anims,
        "clips":{clip:{"frames":info["frames"],"fps":info["fps"],"loop":info.get("loop",True)} for clip,info in report["clips"].items()},
        "swings":{"lunge":"attack"} if "attack" in report["clips"] else {},"layers":[species],"order":{}}
    if volume_atlas:
        volume_atlas.save(path/f"{species}_volume.png",optimize=True)
        visual["volume"] = {"atlas":f"{species}_volume.png",**report["volume"]}
    if "harness" in report:
        visual["harness"] = [poses for clip in report["clips"] for poses in report["harness"][clip]]
    if report.get("strides"):
        visual["stride_px"] = {clip:stride*report["px_per_m"]*visual["pixel_scale"] for clip,stride in report["strides"].items()}
    (path/"visual.json").write_text(json.dumps(visual,indent=2)+"\n")
    font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",20)
    # Actual sprite pixels at 2x, no smoothing, with the same foot anchor per panel.
    panel_width,panel_height = max(360,width*2+32),max(320,height*2+64)
    def preview(clip,row,index):
        return pictures[clip,row,index].crop((left,top,right,bottom)).resize((width*2,height*2),Image.Resampling.NEAREST)
    def place(panel,picture,x,y):
        panel.paste(picture,(x+panel_width//2-visual["origin"][0]*2,
            y+panel_height-24-visual["origin"][1]*2),picture)
    panel = Image.new("RGB",(4*panel_width,2*panel_height),"#3b4243")
    draw = ImageDraw.Draw(panel)
    for row, direction in enumerate(report["directions"]):
        image = preview("idle",row,0)
        x,y = row%4*panel_width,row//4*panel_height
        place(panel,image,x,y)
        draw.text((x+12,y+12),direction,font=font,fill="#eee0c4")
    panel.save(path/"directions.webp",lossless=True)
    for clip, info in report["clips"].items():
        frames = []
        for i in range(info["frames"]):
            frame = Image.new("RGB",(3*panel_width,panel_height),"#3b4243")
            draw = ImageDraw.Draw(frame)
            for n,row in enumerate((1,2,7)):
                image = preview(clip,row,i)
                place(frame,image,n*panel_width,0)
                draw.text((n*panel_width+12,12),f"{clip} / {report['directions'][row]}",font=font,fill="#eee0c4")
            frames.append(frame)
        durations = [round((i+1)*100/info["fps"])*10-round(i*100/info["fps"])*10 for i in range(info["frames"])]
        frames[0].save(path/f"{clip}.gif",save_all=True,append_images=frames[1:],
            duration=durations,loop=0,disposal=2)
    contacts = report.get("contacts",{})
    max_slip = 0
    for clip in ("walk","run"):
        if clip not in report["clips"] or not contacts:
            continue
        for i in range(report["clips"][clip]["frames"]):
            frame = contacts[f"{clip}_{i:02d}"]
            if clip=="walk" and sum(leg["planted"] for leg in frame.values())<2:
                raise ValueError(f"No grounded hoof: {clip} {i}")
            for name,leg in frame.items():
                if abs(leg["sole_z"]-leg["lift"])>.002:
                    raise ValueError(f"Hoof misses its path: {clip}/{i}/{name}")
                following = contacts[f"{clip}_{(i+1)%report['clips'][clip]['frames']:02d}"][name]
                if leg["planted"] and following["planted"]:
                    travel = 1.12 if clip=="walk" else 3.25
                    slip = abs(following["y"]-leg["y"]+travel/report["clips"][clip]["frames"])
                    max_slip = max(max_slip,slip)
                    if slip>.002:
                        raise ValueError(f"Planted hoof slides: {clip}/{i}/{name}: {slip}")
    if contacts and "run" in report["clips"] and not any(not any(leg["planted"] for leg in contacts[f"run_{i:02d}"].values())
            for i in range(report["clips"]["run"]["frames"])):
        raise ValueError("Gallop has no suspension phase")
    verification = {"frames":len(pictures),"directions":8,"clipped_frames":0,
        "alpha_values":sorted(np.unique(np.asarray(atlas)[...,3]).tolist()),
        "frame":[width,height],"atlas":[atlas.width,atlas.height],"origin":visual["origin"],
        "sha256":hashlib.sha256(atlas_path.read_bytes()).hexdigest(),
        "anatomy":report["anatomy"],"max_planted_hoof_slip":max_slip if contacts else None,
        "default_game_content_modified":False,"stage":"candidate; human visual approval required"}
    assert verification["alpha_values"] == [0,255]
    (path/"verification.json").write_text(json.dumps(verification,indent=2)+"\n")
    print(json.dumps(verification))


if __name__ == "__main__":
    main()
