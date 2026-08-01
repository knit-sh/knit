-- knit-marker: a trivial env-only module used by the knit integration tests to
-- prove that a profile-loaded module reaches a setup's activation and, through
-- it, a job body. It sets a single marker variable and nothing else.
setenv("KNIT_MODULE_MARKER", "loaded")
