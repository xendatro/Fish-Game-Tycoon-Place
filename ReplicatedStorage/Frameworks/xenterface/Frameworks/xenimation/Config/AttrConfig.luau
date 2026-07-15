return {
	-- Position & Layout
	pos = {target = "gui", property = "Position", parser = "position"},
	ap = {target = "gui", property = "AnchorPoint", parser = "vector2"},
	cp = {target = "gui", property = "CanvasPosition", parser = "vector2"},
	rot = {target = "gui", property = "Rotation", parser = "rotation"},

	-- Colors (RGB-based)
	bgc = {target = "gui", property = "BackgroundColor3", parser = "color"},
	tc = {target = "gui", property = "TextColor3", parser = "color"},
	ic = {target = "gui", property = "ImageColor3", parser = "color"},
	tsc = {target = "gui", property = "TextStrokeColor3", parser = "color"},
	bc = {target = "gui", property = "BorderColor3", parser = "color"},
	gc = {target = "gui", property = "GroupColor3", parser = "color"},

	-- Transparency
	bgt = {target = "gui", property = "BackgroundTransparency", parser = "number"},
	tt = {target = "gui", property = "TextTransparency", parser = "number"},
	it = {target = "gui", property = "ImageTransparency", parser = "number"},
	gt = {target = "gui", property = "GroupTransparency", parser = "number"},

	-- Other GUI Properties
	tst = {target = "gui", property = "TextStrokeThickness", parser = "number"},
	bsp = {target = "gui", property = "BorderSizePixel", parser = "number"},

	-- Modifiers
	scale = {target = "UIScale", property = "Scale", parser = "number"},
	sth = {target = "UIStroke", property = "Thickness", parser = "number"},
	sbo = {target = "UIStroke", property = "BorderOffset", parser = "udim"},
	str = {target = "UIStroke", property = "Transparency", parser = "number"},
	sc = {target = "UIStroke", property = "Color", parser = "color"},
	cr = {target = "UICorner", property = "CornerRadius", parser = "udim"},
	ar = {target = "UIAspectRatioConstraint", property = "AspectRatio", parser = "number"},
	maxs = {target = "UISizeConstraint", property = "MaxSize", parser = "vector2"},
	mins = {target = "UISizeConstraint", property = "MinSize", parser = "vector2"},
	maxts = {target = "UITextSizeConstraint", property = "MaxTextSize", parser = "vector2"},
	mints = {target = "UITextSizeConstraint", property = "MinTextSize", parser = "vector2"},

	-- Animation Control
	t = {target = "config", property = "duration", parser = "duration"},

	-- Easing Styles
	linear = {target = "config", property = "easingStyle", value = Enum.EasingStyle.Linear},
	quad = {target = "config", property = "easingStyle", value = Enum.EasingStyle.Quad},
	cubic = {target = "config", property = "easingStyle", value = Enum.EasingStyle.Cubic},
	quart = {target = "config", property = "easingStyle", value = Enum.EasingStyle.Quart},
	sine = {target = "config", property = "easingStyle", value = Enum.EasingStyle.Sine},
	exponential = {target = "config", property = "easingStyle", value = Enum.EasingStyle.Exponential},
	circular = {target = "config", property = "easingStyle", value = Enum.EasingStyle.Circular},
	back = {target = "config", property = "easingStyle", value = Enum.EasingStyle.Back},
	bounce = {target = "config", property = "easingStyle", value = Enum.EasingStyle.Bounce},
	elastic = {target = "config", property = "easingStyle", value = Enum.EasingStyle.Elastic},

	-- Easing Directions
	["in"] = {target = "config", property = "easingDirection", value = Enum.EasingDirection.In},
	out = {target = "config", property = "easingDirection", value = Enum.EasingDirection.Out},
	inOut = {target = "config", property = "easingDirection", value = Enum.EasingDirection.InOut},

	-- Special
	initial = {target = "special", parser = "initial"},

	-- Relative Operations
	add = {target = "relative", operation = "add"},
	sub = {target = "relative", operation = "sub"},
	mult = {target = "relative", operation = "mult"},
	div = {target = "relative", operation = "div"},
}