-- mpich: the non-system MPI on the Slurm image, built from source off PATH at
-- /opt/mpich. The system MPI here is OpenMPI (on PATH); loading this module
-- brings the MPICH launcher (mpiexec/mpirun) and libraries into scope and
-- advertises the flavor so tests can prove which install launched.
prepend_path("PATH", "/opt/mpich/bin")
prepend_path("LD_LIBRARY_PATH", "/opt/mpich/lib")
setenv("KNIT_MPI_FLAVOR", "mpich")
