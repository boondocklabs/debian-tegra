#include <cuda.h>
#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <cufft.h>
#include <curand.h>
#include <cusolverDn.h>
#include <cusparse.h>
#include <nvrtc.h>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#define CHECK(x) do { auto s = (x); if (s != 0) { \
  std::fprintf(stderr, "%s:%d: %s failed (%d)\n", __FILE__, __LINE__, #x, int(s)); \
  return 1; } } while (0)
#define EXPECT(x) do { if (!(x)) { \
  std::fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #x); \
  return 1; } } while (0)

__global__ void add_one(int *p) { p[0]++; }

int cuda_test() {
  int *d = nullptr, value = 41;
  CHECK(cudaSetDevice(0));
  CHECK(cudaMalloc((void **)&d, sizeof(value)));
  CHECK(cudaMemcpy(d, &value, sizeof(value), cudaMemcpyHostToDevice));
  add_one<<<1, 1>>>(d);
  CHECK(cudaGetLastError()); CHECK(cudaDeviceSynchronize());
  CHECK(cudaMemcpy(&value, d, sizeof(value), cudaMemcpyDeviceToHost));
  EXPECT(value == 42); CHECK(cudaFree(d));
  return 0;
}

int cublas_test() {
  cublasHandle_t h; float *a, *b, *c;
  const float ah[4] = {1, 3, 2, 4}, bh[4] = {5, 7, 6, 8};
  float ch[4] = {}; const float one = 1, zero = 0;
  CHECK(cublasCreate(&h));
  CHECK(cudaMalloc((void **)&a, sizeof(ah)));
  CHECK(cudaMalloc((void **)&b, sizeof(bh)));
  CHECK(cudaMalloc((void **)&c, sizeof(ch)));
  CHECK(cudaMemcpy(a, ah, sizeof(ah), cudaMemcpyHostToDevice));
  CHECK(cudaMemcpy(b, bh, sizeof(bh), cudaMemcpyHostToDevice));
  CHECK(cublasSgemm(h, CUBLAS_OP_N, CUBLAS_OP_N, 2, 2, 2,
                    &one, a, 2, b, 2, &zero, c, 2));
  CHECK(cudaMemcpy(ch, c, sizeof(ch), cudaMemcpyDeviceToHost));
  EXPECT(ch[0] == 19 && ch[1] == 43 && ch[2] == 22 && ch[3] == 50);
  CHECK(cudaFree(a)); CHECK(cudaFree(b)); CHECK(cudaFree(c));
  CHECK(cublasDestroy(h)); return 0;
}

int cufft_test() {
  cufftHandle h; cufftComplex *d;
  cufftComplex values[4] = {{1, 0}, {0, 0}, {0, 0}, {0, 0}};
  CHECK(cudaMalloc((void **)&d, sizeof(values)));
  CHECK(cudaMemcpy(d, values, sizeof(values), cudaMemcpyHostToDevice));
  CHECK(cufftPlan1d(&h, 4, CUFFT_C2C, 1));
  CHECK(cufftExecC2C(h, d, d, CUFFT_FORWARD));
  CHECK(cudaMemcpy(values, d, sizeof(values), cudaMemcpyDeviceToHost));
  for (auto v : values)
    EXPECT(std::fabs(v.x - 1) < 0.001f && std::fabs(v.y) < 0.001f);
  CHECK(cufftDestroy(h)); CHECK(cudaFree(d)); return 0;
}

int curand_test() {
  curandGenerator_t h; float *d; std::vector<float> values(256);
  CHECK(cudaMalloc((void **)&d, values.size() * sizeof(float)));
  CHECK(curandCreateGenerator(&h, CURAND_RNG_PSEUDO_DEFAULT));
  CHECK(curandSetPseudoRandomGeneratorSeed(h, 1234));
  CHECK(curandGenerateUniform(h, d, values.size()));
  CHECK(cudaMemcpy(values.data(), d, values.size() * sizeof(float),
                   cudaMemcpyDeviceToHost));
  float sum = 0;
  for (float v : values) { EXPECT(std::isfinite(v) && v > 0 && v <= 1); sum += v; }
  EXPECT(sum / values.size() > 0.4f && sum / values.size() < 0.6f);
  CHECK(curandDestroyGenerator(h)); CHECK(cudaFree(d)); return 0;
}

int cusolver_test() {
  cusolverDnHandle_t h; float *d, *work; int *info, result = -1, nwork = 0;
  float values[4] = {4, 1, 1, 3};
  CHECK(cusolverDnCreate(&h));
  CHECK(cudaMalloc((void **)&d, sizeof(values)));
  CHECK(cudaMalloc((void **)&info, sizeof(result)));
  CHECK(cudaMemcpy(d, values, sizeof(values), cudaMemcpyHostToDevice));
  CHECK(cusolverDnSpotrf_bufferSize(h, CUBLAS_FILL_MODE_LOWER, 2, d, 2, &nwork));
  CHECK(cudaMalloc((void **)&work, nwork * sizeof(float)));
  CHECK(cusolverDnSpotrf(h, CUBLAS_FILL_MODE_LOWER, 2, d, 2, work, nwork, info));
  CHECK(cudaMemcpy(&result, info, sizeof(result), cudaMemcpyDeviceToHost));
  CHECK(cudaMemcpy(values, d, sizeof(values), cudaMemcpyDeviceToHost));
  EXPECT(result == 0 && std::fabs(values[0] - 2) < 0.001f &&
         std::fabs(values[1] - 0.5f) < 0.001f &&
         std::fabs(values[3] - std::sqrt(2.75f)) < 0.001f);
  CHECK(cudaFree(d)); CHECK(cudaFree(work)); CHECK(cudaFree(info));
  CHECK(cusolverDnDestroy(h)); return 0;
}

int cusparse_test() {
  cusparseHandle_t h; cusparseSpMatDescr_t m;
  cusparseDnVecDescr_t vx, vy;
  int *rows, *cols; float *values, *x, *y; void *buffer;
  const int rh[3] = {0, 1, 2}, ch[2] = {0, 1};
  const float vh[2] = {2, 3}, xh[2] = {4, 5}; float yh[2] = {};
  const float one = 1, zero = 0; size_t bytes = 0;
  CHECK(cusparseCreate(&h));
  CHECK(cudaMalloc((void **)&rows, sizeof(rh)));
  CHECK(cudaMalloc((void **)&cols, sizeof(ch)));
  CHECK(cudaMalloc((void **)&values, sizeof(vh)));
  CHECK(cudaMalloc((void **)&x, sizeof(xh)));
  CHECK(cudaMalloc((void **)&y, sizeof(yh)));
  CHECK(cudaMemcpy(rows, rh, sizeof(rh), cudaMemcpyHostToDevice));
  CHECK(cudaMemcpy(cols, ch, sizeof(ch), cudaMemcpyHostToDevice));
  CHECK(cudaMemcpy(values, vh, sizeof(vh), cudaMemcpyHostToDevice));
  CHECK(cudaMemcpy(x, xh, sizeof(xh), cudaMemcpyHostToDevice));
  CHECK(cusparseCreateCsr(&m, 2, 2, 2, rows, cols, values,
                          CUSPARSE_INDEX_32I, CUSPARSE_INDEX_32I,
                          CUSPARSE_INDEX_BASE_ZERO, CUDA_R_32F));
  CHECK(cusparseCreateDnVec(&vx, 2, x, CUDA_R_32F));
  CHECK(cusparseCreateDnVec(&vy, 2, y, CUDA_R_32F));
  CHECK(cusparseSpMV_bufferSize(h, CUSPARSE_OPERATION_NON_TRANSPOSE,
                                &one, m, vx, &zero, vy, CUDA_R_32F,
                                CUSPARSE_SPMV_ALG_DEFAULT, &bytes));
  CHECK(cudaMalloc(&buffer, bytes ? bytes : 1));
  CHECK(cusparseSpMV(h, CUSPARSE_OPERATION_NON_TRANSPOSE,
                     &one, m, vx, &zero, vy, CUDA_R_32F,
                     CUSPARSE_SPMV_ALG_DEFAULT, buffer));
  CHECK(cudaMemcpy(yh, y, sizeof(yh), cudaMemcpyDeviceToHost));
  EXPECT(yh[0] == 8 && yh[1] == 15);
  CHECK(cusparseDestroySpMat(m));
  CHECK(cusparseDestroyDnVec(vx)); CHECK(cusparseDestroyDnVec(vy));
  CHECK(cudaFree(rows)); CHECK(cudaFree(cols)); CHECK(cudaFree(values));
  CHECK(cudaFree(x)); CHECK(cudaFree(y)); CHECK(cudaFree(buffer));
  CHECK(cusparseDestroy(h)); return 0;
}

int nvrtc_test() {
  const char *source = "extern \"C\" __global__ void probe(int *p) { p[0] += 7; }";
  nvrtcProgram program;
  CHECK(nvrtcCreateProgram(&program, source, "probe.cu", 0, nullptr, nullptr));
  const char *options[] = {"--gpu-architecture=sm_53"};
  nvrtcResult compiled = nvrtcCompileProgram(program, 1, options);
  size_t log_size = 0; CHECK(nvrtcGetProgramLogSize(program, &log_size));
  if (compiled != NVRTC_SUCCESS) {
    std::string log(log_size, '\0');
    CHECK(nvrtcGetProgramLog(program, log.data()));
    std::fprintf(stderr, "%s\n", log.c_str()); return 1;
  }
  size_t cubin_size = 0; CHECK(nvrtcGetCUBINSize(program, &cubin_size));
  std::vector<char> cubin(cubin_size); CHECK(nvrtcGetCUBIN(program, cubin.data()));
  CHECK(nvrtcDestroyProgram(&program));
  CUdevice device; CUcontext context; CUmodule module; CUfunction function;
  CUdeviceptr d; int value = 5;
  CHECK(cuInit(0)); CHECK(cuDeviceGet(&device, 0));
  CHECK(cuCtxCreate(&context, 0, device));
  CHECK(cuModuleLoadData(&module, cubin.data()));
  CHECK(cuModuleGetFunction(&function, module, "probe"));
  CHECK(cuMemAlloc(&d, sizeof(value)));
  CHECK(cuMemcpyHtoD(d, &value, sizeof(value)));
  void *args[] = {&d};
  CHECK(cuLaunchKernel(function, 1, 1, 1, 1, 1, 1, 0, nullptr, args, nullptr));
  CHECK(cuCtxSynchronize()); CHECK(cuMemcpyDtoH(&value, d, sizeof(value)));
  EXPECT(value == 12);
  CHECK(cuMemFree(d)); CHECK(cuModuleUnload(module));
  CHECK(cuCtxDestroy(context)); return 0;
}

int main(int argc, char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: cuda-probes {cuda|cublas|cufft|curand|cusolver|cusparse|nvrtc}\n");
    return 2;
  }
  struct Test { const char *name; int (*run)(); };
  const Test tests[] = {{"cuda", cuda_test}, {"cublas", cublas_test},
                        {"cufft", cufft_test}, {"curand", curand_test},
                        {"cusolver", cusolver_test}, {"cusparse", cusparse_test},
                        {"nvrtc", nvrtc_test}};
  for (auto test : tests) if (std::strcmp(test.name, argv[1]) == 0) {
    int result = test.run();
    if (result == 0) std::printf("PASS %s\n", test.name);
    return result;
  }
  std::fprintf(stderr, "unknown test: %s\n", argv[1]); return 2;
}
