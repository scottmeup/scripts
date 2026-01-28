import cadquery as cq

# -------- PARAMETERS --------
BED_W = 1530
BED_L = 2030
DECK_Z = 2200
RAIL_TOP_Z = 2800

POST = 90
THK = 45
BEAM_L = 190
BEAM_S = 140
JOIST = 140

# -------- POSTS --------
posts = (
    cq.Workplane("XY")
    .rect(BED_W-POST, BED_L-POST, forConstruction=True)
    .vertices()
    .rect(POST, POST)
    .extrude(RAIL_TOP_Z)
)

# -------- FRAME --------
frame = (
    cq.Workplane("XY")
    .workplane(offset=DECK_Z-THK)
    .rect(BED_W, THK).extrude(BEAM_L)
    .faces(">Y").workplane().rect(BED_W, THK).extrude(BEAM_L)
    .faces("<X").workplane().rect(THK, BED_L).extrude(BEAM_S)
    .faces(">X").workplane().rect(THK, BED_L).extrude(BEAM_S)
)

# -------- JOISTS --------
joists = cq.Workplane("XY")
for y in range(450, BED_L, 450):
    joists = joists.union(
        cq.Workplane("XY")
        .translate((BED_W/2, y, DECK_Z-THK))
        .rect(BED_W, THK)
        .extrude(JOIST)
    )

# -------- GUARD --------
guard = (
    cq.Workplane("XY")
    .workplane(offset=RAIL_TOP_Z-THK)
    .rect(BED_W, THK).extrude(THK)
    .faces(">Y").workplane().rect(BED_W, THK).extrude(THK)
    .faces("<X").workplane().rect(THK, BED_L).extrude(THK)
)

model = posts.union(frame).union(joists).union(guard)

cq.exporters.export(model, "loft_bed.step")
