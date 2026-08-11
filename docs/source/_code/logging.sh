#!/bin/bash

# Showcase for the Logging stitch category: emitting messages at the right
# level, raising the threshold from a command body, and framing a long-running
# command's output. Local backend only, so it runs anywhere with bash + sqlite3.

source knit.sh

knit_set_program_description "Demonstrate logging and framed output."

# START levels
knit_register "work" do_work "Do some work, narrating at several log levels."
do_work() {
    knit_trace   "entering do_work"             # shown only at --log-level trace
    knit_debug   "computing the result"         # trace or debug
    knit_info    "starting the computation"     # info and below (the default)
    knit_warning "input looks unusually large"  # warning and below
    knit_error   "a recoverable step failed"    # error and below
    # knit_fatal prints at ANY level and then exits non-zero:
    #   knit_fatal "unrecoverable: %s" "${reason}"
    echo "done"
}
knit_done
# END levels

# START setlevel
# Raise the threshold from inside a body so only warnings and above surface.
# The same effect is available before launch with KNIT_LOG_LEVEL=warning.
knit_register "quiet" go_quiet "Run the work quietly (warnings and errors only)."
go_quiet() {
    knit_log_set_level warning
    do_work
}
knit_done
# END setlevel

# START framed
# Pipe a long-running command's output into knit_framed to keep it inside a
# fixed, scrolling box with a title. On a non-TTY (a log file, CI) the input is
# forwarded unchanged, so framing never corrupts captured output.
knit_register "build" do_build "Build something, framing the output."
do_build() {
    build_steps | knit_framed 10 60 --title "Building" --cleanup
}
build_steps() {
    echo "step 1/3"
    echo "step 2/3"
    echo "step 3/3"
}
knit_done
# END framed

knit "$@"
