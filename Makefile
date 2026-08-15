# Prefer an explicitly selected toolkit (CUDA_HOME/CUDA_PATH, or whatever nvcc
# an `module load cuda/...` put on PATH) over the distro one.  /usr/local/cuda
# may point at a toolkit that is too new: CUDA 13 dropped compute_60/compute_70,
# so building against it silently produces a binary that cannot run on Pascal
# (P100) or Volta (V100, Titan V).
NVCC_ON_PATH := $(shell command -v nvcc 2>/dev/null)

ifneq ($(strip $(CUDA_HOME)),)
CUDAPATH ?= $(CUDA_HOME)
else ifneq ($(strip $(CUDA_PATH)),)
CUDAPATH ?= $(CUDA_PATH)
else ifneq ($(strip $(NVCC_ON_PATH)),)
CUDAPATH ?= $(patsubst %/bin/nvcc,%,$(NVCC_ON_PATH))
else ifneq ("$(wildcard /usr/bin/nvcc)", "")
CUDAPATH ?= /usr
else ifneq ("$(wildcard /usr/local/cuda/bin/nvcc)", "")
CUDAPATH ?= /usr/local/cuda
endif

IS_JETSON   ?= $(shell if grep -Fwq "Jetson" /proc/device-tree/model 2>/dev/null; then echo true; else echo false; fi)
NVCC        :=  ${CUDAPATH}/bin/nvcc
CCPATH      ?=

override CFLAGS   ?=
override CFLAGS   += -O3
override CFLAGS   += -Wno-unused-result
override CFLAGS   += -I${CUDAPATH}/include
override CFLAGS   += -std=c++11
override CFLAGS   += -DIS_JETSON=${IS_JETSON}

override LDFLAGS  ?=
override LDFLAGS  += -lcuda
override LDFLAGS  += -L${CUDAPATH}/lib64
override LDFLAGS  += -L${CUDAPATH}/lib64/stubs
override LDFLAGS  += -L${CUDAPATH}/lib
override LDFLAGS  += -L${CUDAPATH}/lib/stubs
override LDFLAGS  += -Wl,-rpath=${CUDAPATH}/lib64
override LDFLAGS  += -Wl,-rpath=${CUDAPATH}/lib
override LDFLAGS  += -lcublas
override LDFLAGS  += -lcudart

COMPUTE      ?= 75
CUDA_VERSION ?= 11.8.0
IMAGE_DISTRO ?= ubi8

# Fat binary covering every GPU generation in the cluster.  Requires CUDA 12.x:
# 12.9 is the last toolkit that can still emit sm_60/sm_70.
#   sm_60  Tesla P100
#   sm_61  GeForce/Quadro Pascal (GTX 10xx, P4/P40)
#   sm_70  Tesla V100, Titan V
#   sm_75  RTX 2080, Quadro RTX 5000
#   sm_80  A100
#   sm_86  RTX A5000, RTX A6000
#   sm_89  RTX 6000 Ada
#   sm_90  H100
#   sm_120 RTX PRO 6000 Blackwell
# The trailing compute_120 entry keeps PTX in the fatbin so the driver can JIT
# for a future architecture this toolkit has never heard of.
SM_TARGETS ?= 60 61 70 75 80 86 89 90 120
PTX_TARGET ?= 120
GENCODE ?= $(foreach sm,$(SM_TARGETS),-gencode arch=compute_$(sm),code=sm_$(sm)) \
           $(foreach ptx,$(PTX_TARGET),-gencode arch=compute_$(ptx),code=compute_$(ptx))

override NVCCFLAGS ?=
override NVCCFLAGS += -I${CUDAPATH}/include
override NVCCFLAGS += --threads 0
override NVCCFLAGS += -Wno-deprecated-gpu-targets
ifneq ($(strip $(GENCODE)),)
override NVCCFLAGS += ${GENCODE}
else ifneq ($(strip $(COMPUTE)),)
override NVCCFLAGS += -arch=compute_$(subst .,,${COMPUTE})
endif

# nvcc refuses to run with a host compiler newer than the toolkit knows about,
# and Ubuntu 26.04 defaults to GCC 15 while CUDA 12.9 tops out at GCC 14.  Point
# it at a supported g++ instead.  -allow-unsupported-compiler is NOT a way out
# here: GCC 15's libstdc++ uses builtins (__array_rank etc.) that the 12.9
# frontend cannot parse, so it fails even with the version check disabled.
CUDA_MAX_GCC := $(shell sed -n 's/^#if __GNUC__ > \([0-9]*\).*/\1/p' \
                    ${CUDAPATH}/include/crt/host_config.h 2>/dev/null | head -1)
HOST_GCC     := $(shell g++ -dumpversion 2>/dev/null | cut -d. -f1)
CCBIN        ?= $(firstword $(wildcard /usr/bin/g++-14 /usr/bin/g++-13 /usr/bin/g++-12))

ifneq ($(strip $(CUDA_MAX_GCC)),)
ifeq ($(shell test "$(HOST_GCC)" -gt "$(CUDA_MAX_GCC)" 2>/dev/null && echo yes),yes)
ifneq ($(strip $(CCBIN)),)
override NVCCFLAGS += -ccbin ${CCBIN}
else
$(error No supported host compiler found: nvcc in ${CUDAPATH} needs GCC <= ${CUDA_MAX_GCC}, \
        but g++ is ${HOST_GCC} and no g++-14/13/12 is installed.  Install one (apt install g++-14) \
        or point at it with CCBIN=/path/to/g++)
endif
endif
endif

# glibc 2.41 added the C23 sinpi/cospi/tanpi/rsqrt family, whose declarations
# collide with CUDA 12.9's own host declarations of the same names (the glibc
# ones are noexcept, CUDA's are not).  glibc only exposes them when _GNU_SOURCE
# is defined, and compare.cu is pure device code that needs nothing from glibc,
# so turn the feature set off for this one compile.
GLIBC_VER := $(shell getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $$2}')
ifeq ($(shell printf '%s\n' 2.41 "$(GLIBC_VER)" | sort -V | head -1),2.41)
override NVCCFLAGS += -Xcompiler -U_GNU_SOURCE
endif

IMAGE_NAME ?= gpu-burn

.PHONY: clean check-arch
.DEFAULT_GOAL := gpu_burn

# Fail with one readable line instead of a wall of nvcc errors when the selected
# toolkit cannot emit a requested architecture.  Order-only so it does not force
# a rebuild of the fatbin.
check-arch:
	@test -x "${NVCC}" || { echo "ERROR: no nvcc at ${NVCC} (set CUDAPATH= or load a cuda module)"; exit 1; }
	@echo "Using $$(${NVCC} --version | grep -o 'release [0-9.]*') from ${CUDAPATH}"
	@codes="$$(${NVCC} --list-gpu-code)"; rc=0; \
	for sm in ${SM_TARGETS}; do \
	    echo "$$codes" | grep -qx "sm_$$sm" || { echo "ERROR: this toolkit cannot target sm_$$sm"; rc=1; }; \
	done; \
	test $$rc -eq 0 || { \
	    echo "       CUDA 13 removed sm_50/52/53/60/61/62/70/72 -- P100, V100 and Titan V"; \
	    echo "       need a CUDA 12.x toolkit (12.9 is the last one).  Either load it"; \
	    echo "       (module load cuda/cuda-12.9) or build with CUDAPATH=/path/to/cuda-12.9."; \
	    exit 1; }

gpu_burn: gpu_burn-drv.o compare.fatbin
	g++ -o $@ $< -O3 ${LDFLAGS}

%.o: %.cpp
	g++ ${CFLAGS} -c $<

%.fatbin: %.cu | check-arch
	PATH="${PATH}:${CCPATH}:." ${NVCC} ${NVCCFLAGS} -fatbin $< -o $@

clean:
	$(RM) *.fatbin *.o gpu_burn

image:
	docker build --build-arg COMPUTE=${COMPUTE} --build-arg CUDA_VERSION=${CUDA_VERSION} --build-arg IMAGE_DISTRO=${IMAGE_DISTRO} -t ${IMAGE_NAME} .
