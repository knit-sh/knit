#!/bin/bash

# doc-check: source-only
#
# Tutorial snapshot --- STEP 1: a plain command that calls the julia-fractal
# binary directly. This is the starting point the tutorial grows, over the
# following steps, into a Spack-backed, MPI-parallel, fully recorded experiment.
#
# It is marked source-only because it cannot run in plain CI: the julia-fractal
# program does not exist yet (a later step builds it). check-docs therefore only
# syntax-checks this file. The tutorial prose deliberately shows this command
# *failing* with "julia-fractal: command not found", which is what motivates the
# setup introduced in the next step.

# START julia
#!/usr/bin/env bash
source knit.sh

knit_set_program_description "Render a Julia-set fractal."

knit_register julia "julia" "Render a Julia-set fractal to a PNG."
knit_with_optional "width:integer"    "800"    "Image width in pixels."
knit_with_optional "height:integer"   "600"    "Image height in pixels."
knit_with_optional "c-re:real"        "-0.8"   "Real part of the Julia constant c."
knit_with_optional "c-im:real"        "0.156"  "Imaginary part of the Julia constant c."
knit_with_optional "max-iter:integer" "1000"   "Maximum iterations per pixel."
knit_with_optional "colormap:string"  "fire"   "Palette: grayscale | fire | ocean."
knit_with_optional "output:string"    ""       "PNG file to write (empty = no file)."
julia() {
    local width height c_re c_im max_iter colormap output
    width=$(knit_get_parameter "width" "$@")
    height=$(knit_get_parameter "height" "$@")
    c_re=$(knit_get_parameter "c-re" "$@")
    c_im=$(knit_get_parameter "c-im" "$@")
    max_iter=$(knit_get_parameter "max-iter" "$@")
    colormap=$(knit_get_parameter "colormap" "$@")
    output=$(knit_get_parameter "output" "$@")

    # The binary takes its arguments positionally:
    #   width height c_re c_im max_iter [output] [colormap]
    julia-fractal "${width}" "${height}" "${c_re}" "${c_im}" "${max_iter}" \
        "${output}" "${colormap}"
}
knit_done

knit "$@"
# END julia
