extends TestCase

func _visual() -> Dictionary:
	return {"format":"ro","mode":"character","animal":true,"pixel_scale":.25,
		"frame":[8,8],"origin":[4,7],"columns":9,"layers":["animal"],"order":{},
		"anims":{"idle":[0,1],"walk":[1,4],"run":[5,4]},
		"clips":{"idle":{"frames":1,"fps":1},"walk":{"frames":4,"fps":8},"run":{"frames":4,"fps":12}},
		"stride_px":{"walk":16.0,"run":24.0}}

func _texture() -> Texture2D:
	var image := Image.create(72,64,false,Image.FORMAT_RGBA8)
	image.fill(Color(.5,.5,.5,1))
	return ImageTexture.create_from_image(image)

func test_animal_coat_does_not_receive_the_human_skin_palette() -> void:
	var visual := _visual()
	var animal := RoSprite.new(_texture(),visual,[],{"colors":{"skin":"#ff0000"}})
	check((animal.get_child(0) as Sprite2D).material==null,"grey fur remains fur even with human colours in a look")
	visual.erase("animal")
	var human := RoSprite.new(_texture(),visual,[],{})
	check((human.get_child(0) as Sprite2D).material is ShaderMaterial,"human skin keeps its existing colour shader")
	animal.free()
	human.free()

func test_slow_running_creature_uses_the_authoritative_gait() -> void:
	var animal := RoSprite.new(_texture(),_visual(),[],{})
	animal.running_hint = 1
	animal.show_at(Vector2.ZERO,.1,true)
	animal.show_at(Vector2(.5,0),.1,true)
	eq(animal._clip,"run","a slow fleeing cow can run without reaching a human sprint threshold")
	animal.running_hint = 0
	animal.show_at(Vector2(8,0),.01,true)
	eq(animal._clip,"walk","a fast snapshot correction does not turn a walking animal into a runner")
	animal.free()

func test_same_travel_plays_same_stride_at_different_update_rates() -> void:
	var a := RoSprite.new(_texture(),_visual(),[],{})
	var b := RoSprite.new(_texture(),_visual(),[],{})
	for animal: RoSprite in [a,b]:
		animal.running_hint = 0
		animal.show_at(Vector2.ZERO,.1,true)
	for i in range(1,11): a.show_at(Vector2(i,0),.02,true)
	for i in range(1,3): b.show_at(Vector2(i*5,0),.1,true)
	eq(a._index,2,"ten pixels cover two and a half frames of a sixteen-pixel stride")
	eq(a._index,b._index,"frame rate and snapshot grouping do not change foot travel")
	check(is_equal_approx(a._walk,b._walk),"the gait clock follows distance")
	a.free()
	b.free()

func test_tiny_strides_have_a_readable_cadence_at_game_speeds() -> void:
	for running: int in [0,1]:
		var visual := _visual()
		visual.stride_px = {"walk":2,"run":3}
		var animal := RoSprite.new(_texture(),visual,[],{})
		animal.running_hint = running
		animal.show_at(Vector2.ZERO,.1,true)
		animal.show_at(Vector2(12,0),.1,true)
		var clip: Dictionary = visual.clips["run" if running else "walk"]
		var cycles: float = animal._walk*float(clip.fps)/int(clip.frames)
		check(is_equal_approx(cycles,.4 if running else .3),"fast snapshot corrections and tiny paws cannot strobe through whole cycles")
		animal.free()

func test_animal_metadata_rejects_bad_stride_and_incomplete_harness() -> void:
	var visual := _visual()
	visual.atlas = "animal.png"
	var registry := ContentRegistry.new()
	registry._check_ro("animal",visual,"")
	eq(registry.errors,PackedStringArray())
	visual.stride_px.walk = 0
	visual.harness = [[[]]]
	visual.volume = {"atlas":"animal_volume.png","span":6,"px_per_m":77,"elevation":90}
	registry._check_ro("animal",visual,"")
	eq(registry.errors.size(),3,"invalid gait, attachment rows and volume camera are rejected before rendering")

func test_game_animals_use_complete_eight_direction_ro_sheets() -> void:
	var content := ContentRegistry.load_packs(["res://content/base"])
	eq(content.errors,PackedStringArray())
	for species: String in ["horse","deer","cow","wolf","fox","arctic_fox","hare","bear","polar_bear","sheep","chicken","cave_rat","cave_spider"]:
		var visual := content.visual_of("base:"+species)
		eq(visual.get("format"),"ro",species)
		var variants := [visual]
		for alt: Dictionary in visual.get("alternates",[]): variants.append(visual.merged(alt,true))
		for sheet: Dictionary in variants:
			check(sheet.get("animal",false),"fur keeps its original palette")
			check(sheet.has("volume"),"the pose has its own body surface")
			var texture := Art.texture(sheet["atlas_path"])
			var frame := Vector2(sheet["frame"][0],sheet["frame"][1])
			var origin := Vector2(sheet["origin"][0],sheet["origin"][1])
			var corner := BillboardActor3D.DOLL_FEET-origin
			check(corner.x>0 and corner.y>0 and corner.x+frame.x<384 and corner.y+frame.y<384,"the entire pose range fits the actor viewport")
			var doll := Art.character_sprite(content,sheet,{"body_plan":"base:"+species}) as RoSprite
			for clip: String in sheet["clips"]:
				for row in 8:
					for index in int(sheet["clips"][clip]["frames"]):
						doll.pinned = [clip,row,index]
						doll._frame({},0)
						var region := (doll.get_child(0) as Sprite2D).region_rect
						check(Rect2(Vector2.ZERO,texture.get_size()).encloses(region),"every direction and frame lies within its atlas")
			doll.free()
