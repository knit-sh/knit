-- openmpi: the MPI on the Flux image, installed from the distribution into
-- /usr/lib64/openmpi and kept off PATH by default. Loading this module brings
-- the OpenMPI compilers and libraries into scope so an MPI app builds and runs
-- under `flux run` (OpenMPI's "pmix: flux" component bootstraps from the Flux
-- PMI). It advertises the flavor so tests can prove which install launched.
prepend_path("PATH", "/usr/lib64/openmpi/bin")
prepend_path("LD_LIBRARY_PATH", "/usr/lib64/openmpi/lib")
setenv("KNIT_MPI_FLAVOR", "openmpi")
