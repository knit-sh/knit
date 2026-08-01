-- openmpi: the non-system MPI on the PBS image, built from source off PATH at
-- /opt/openmpi. The system MPI here is MPICH (on PATH); loading this module
-- brings the OpenMPI launcher (mpirun) and libraries into scope and advertises
-- the flavor so tests can prove which install launched.
prepend_path("PATH", "/opt/openmpi/bin")
prepend_path("LD_LIBRARY_PATH", "/opt/openmpi/lib")
setenv("KNIT_MPI_FLAVOR", "openmpi")
