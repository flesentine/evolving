"""Add editable Bronze Age court furnishings to the shared Bronze library."""
import math
from pathlib import Path
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
from author_neolithic_people import patch, profile
from build_bronze_reference import COLLECTION, SOURCE
from build_buildings import MB
from build_variants import build_object


def beam(mesh, a, b, thickness, tile, sides=4):
    start, end = Vector(a), Vector(b)
    axis = (end - start).normalized()
    across = axis.cross(Vector((0, 0, 1)))
    if across.length < .001:
        across = axis.cross(Vector((0, 1, 0)))
    across.normalize()
    other = axis.cross(across)
    radius = thickness / (math.sqrt(2) if sides == 4 else 2)
    ring = []
    for i in range(sides):
        angle = math.tau * (i + .5) / sides
        ring.append(radius * (across * math.cos(angle) + other * math.sin(angle)))
    uv = [patch(tile, 0, 0), patch(tile, 1, 0), patch(tile, 1, 1), patch(tile, 0, 1)]
    for i, point in enumerate(ring):
        next_point = ring[(i + 1) % sides]
        mesh.quad_out(tuple(start + point), tuple(start + next_point),
                      tuple(end + next_point), tuple(end + point),
                      tuple(point + next_point), *uv)
        mesh.tri_out(tuple(start), tuple(start + point), tuple(start + next_point),
                     tuple(-axis), *uv[:3])
        mesh.tri_out(tuple(end), tuple(end + point), tuple(end + next_point),
                     tuple(axis), *uv[:3])


def loom():
    m = MB()
    for sign in (-1, 1):
        x = sign * .66
        beam(m, (x, -.105, .145), (x * .98, 1.65, -.10), .10, "planks")
        beam(m, (x, -.105, -.42), (x, 1.03, -.02), .085, "oak")
        for dy in (0, .033):
            m.box((x * .98, 1.51 + dy, -.088), (.15, .017, .145), "thatch")
    beam(m, (-.752, 1.55, -.025), (.752, 1.55, -.025), .105, "planks")
    beam(m, (-.69, .93, .072), (.69, .93, .072), .040, "oak")
    m.box((0, 1.26, .03), (.96, .498, .020), "plaster")
    for y in (1.05, 1.085, 1.205, 1.234, 1.419):
        m.box((0, y, .03), (.965, .018, .027), "thatch")
    for x in (-.465, .465):
        m.box((x, 1.26, .03), (.033, .49, .027), "daub")
    for i in range(9):
        x = (i - 4) * .105
        y = .43 + (i % 3) * .019
        beam(m, (x, 1.014, .046), (x, y + .083, .07), .014, "plaster")
        # Variations in fired-clay weights and the doubled hang loop.
        for side in (-1, 1):
            beam(m, (x, y + .095, .07), (x + side * .024, y + .028, .078), .010, "thatch")
        profile(m, [(y-.065,0,0),(y-.063,.036,.035),(y+.018,.045,.037),
                    (y+.043,.025,.023),(y+.047,0,0)], "brick" if i % 3 else "daub",
                6, centre=(x,.072))
    return m


def pottery():
    m = MB()
    profile(m, [(-.073,0,0),(-.073,.112,.104),(.04,.121,.113),(.19,.214,.202),
                (.30,.226,.214),(.402,.16,.15),(.468,.135,.128),(.491,.157,.147),
                (.513,.156,.145),(.515,.137,.13),(.483,.116,.11),(.403,.13,.122),
                (.30,.196,.184),(.15,.17,.159),(.045,.09,.085),(.043,0,0)],
            "brick", 16, centre=(-.13,-.06))
    profile(m, [(.333,.204,.194),(.351,.196,.186)], "daub", 16, centre=(-.13,-.06))
    profile(m, [(-.073,0,0),(-.073,.092,.084),(.027,.132,.123),(.109,.193,.178),
                (.158,.197,.183),(.168,.185,.173),(.155,.174,.162),(.082,.14,.131),
                (.024,.087,.080),(.018,0,0)], "tile", 14, centre=(.29,.104))
    return m


def cooking_pot():
    m = MB()
    profile(m, [(-.085,0,0),(-.085,.134,.126),(.02,.144,.135),(.13,.209,.196),
                (.247,.218,.205),(.337,.182,.170),(.407,.153,.147),
                (.417,.177,.167),(.436,.177,.166),(.440,.155,.147),
                (.409,.135,.128),(.33,.162,.149),(.24,.196,.179),
                (.13,.183,.169),(.035,.115,.11),(.033,0,0)], "daub", 16)
    profile(m, [(.021,.146,.137),(.111,.201,.190),(.166,.216,.203)], "dark", 16)
    for side in (-1, 1):
        points = [(side*.174,.345,0),(side*.247,.326,0),
                  (side*.256,.246,0),(side*.21,.213,0)]
        for a, b in zip(points, points[1:]):
            beam(m, a, b, .048, "daub", 6)
    return m


def basket():
    m = MB()
    profile(m, [(-.073,0,0),(-.073,.176,.13),(.05,.185,.137),(.202,.252,.186),
                (.302,.271,.203),(.315,.259,.193),(.278,.240,.180),(.07,.171,.127),
                (.048,.155,.117),(.043,0,0)], "thatch", 14)
    for i, y in enumerate((.064,.106,.148,.190,.232,.274,.310)):
        rx = .185 + (y - .05) * .35
        rz = rx * .75
        profile(m, [(y-.010,rx+.005,rz+.006),(y+.006,rx+.011,rz+.010),
                    (y+.014,rx+.004,rz+.004)], "planks" if i % 2 else "oak", 14)
    for i in range(14):
        angle = i * math.tau / 14
        c, s = math.cos(angle), math.sin(angle)
        beam(m, (.18*c,.026,.137*s), (.27*c,.313,.201*s), .014, "thatch")
    for side in (-1, 1):
        points = [(side*.246,.25,-.088),(side*.282,.342,-.067),(side*.296,.367,0),
                  (side*.282,.342,.067),(side*.246,.25,.088)]
        for a,b in zip(points,points[1:]):
            beam(m,a,b,.027,"planks",5)
    return m


def workbench():
    m = MB()
    for x in (-.48,.49):
        for z in (-.195,.195):
            beam(m, (x*1.09,-.103,z*1.18), (x,.72,z), .10, "oak")
        beam(m, (x,.33,-.237), (x,.33,.237), .066, "planks")
    beam(m, (-.54,.42,-.15), (.55,.42,-.15), .076, "oak")
    for index, z in enumerate((-.194,0,.193)):
        m.box((-.018 * index,.746,z), (1.31-.031*index,.089,.186), "planks")

    # Hafted socketed axe lying flat on the boards. Metal faces use the
    # atlas metal tile so Evolving can shade the bronze separately.
    beam(m, (-.481,.815,-.112), (.10,.817,.021), .047, "oak", 6)
    beam(m, (.063,.816,.012), (.176,.823,.095), .061, "oak", 6)
    outline = [(.122,.035),(.203,.013),(.288,.045),(.343,.13),
               (.312,.197),(.221,.159),(.145,.114)]
    base = [(x,.792,z) for x,z in outline]
    top = [(x, .812 if i in (3,4) else .855, z) for i,(x,z) in enumerate(outline)]
    tex = [patch("metal",0,0),patch("metal",1,0),patch("metal",1,1),patch("metal",0,1)]
    for i in range(len(base)):
        j = (i + 1) % len(base)
        m.quad_out(base[i],base[j],top[j],top[i],
                   ((base[i][0]+base[j][0])*.5-.22, 0, (base[i][2]+base[j][2])*.5-.10),*tex)
    for ring, normal in ((base,(0,-1,0)),(top,(0,1,0))):
        for i in range(1,len(ring)-1):
            m.tri_out(ring[0],ring[i],ring[i+1],normal,*tex[:3])
    return m


def main():
    bpy.ops.wm.open_mainfile(filepath=str(SOURCE), load_ui=True, use_scripts=False)
    exports = bpy.data.collections[COLLECTION]
    craft = exports.children.get("Craft Props")
    if craft is None:
        craft = bpy.data.collections.new("Craft Props")
        exports.children.link(craft)
    atlas = exports.all_objects["bronze-01"].data.materials[0]
    for index, (name, mesh) in enumerate((("loom",loom()),("pottery",pottery()),
                                         ("basket",basket()),("workbench",workbench()),
                                         ("cookpot",cooking_pot()))):
        name = "bronze-prop-" + name
        old = craft.objects.get(name)
        if old is not None:
            bpy.data.objects.remove(old, do_unlink=True)
        obj = build_object(mesh, name, ((index-1.5)*3,-75,0), atlas)
        for parent in tuple(obj.users_collection):
            parent.objects.unlink(obj)
        craft.objects.link(obj)
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE), compress=True)


if __name__ == "__main__":
    main()
