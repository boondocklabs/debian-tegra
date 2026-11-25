#include <cuda.h>
#include <cuda_fp16.h>
#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <cufft.h>
#include <curand.h>
#include <cusolverDn.h>
#include <cusparse.h>
#include <nvrtc.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <dlfcn.h>
#include <memory>
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

using BenchmarkClock = std::chrono::steady_clock;
constexpr int benchmark_iterations = 20;

// Stream events exclude setup and validation, including in-place input resets.
template <typename Submit, typename Prepare>
int benchmark_ms(cudaStream_t stream, int seconds, Submit submit,
                 Prepare prepare, float &median_ms) {
  constexpr int warmup = 5, minimum_batches = 5;
  cudaEvent_t start, stop;
  CHECK(cudaEventCreate(&start));
  CHECK(cudaEventCreate(&stop));
  CHECK(prepare());
  for (int i = 0; i < warmup; ++i)
    CHECK(submit(i));
  CHECK(cudaStreamSynchronize(stream));

  std::vector<float> timings;
  auto deadline = BenchmarkClock::now() + std::chrono::seconds(seconds);
  do {
    CHECK(prepare());
    CHECK(cudaEventRecord(start, stream));
    for (int i = 0; i < benchmark_iterations; ++i)
      CHECK(submit(i));
    CHECK(cudaEventRecord(stop, stream));
    CHECK(cudaEventSynchronize(stop));
    float ms;
    CHECK(cudaEventElapsedTime(&ms, start, stop));
    EXPECT(std::isfinite(ms) && ms > 0);
    timings.push_back(ms / benchmark_iterations);
  } while (timings.size() < minimum_batches || BenchmarkClock::now() < deadline);
  std::sort(timings.begin(), timings.end());
  median_ms = timings[timings.size() / 2];
  CHECK(cudaEventDestroy(start));
  CHECK(cudaEventDestroy(stop));
  return 0;
}

template <typename Submit>
int benchmark_ms(cudaStream_t stream, int seconds, Submit submit, float &median_ms) {
  return benchmark_ms(stream, seconds, [&](int) { return submit(); },
                      [] { return 0; }, median_ms);
}

int benchmark_copy(cudaStream_t stream, int seconds) {
  constexpr size_t bytes = 32 * 1024 * 1024;
  unsigned char *src, *dst;
  CHECK(cudaMalloc((void **)&src, bytes));
  CHECK(cudaMalloc((void **)&dst, bytes));
  CHECK(cudaMemsetAsync(src, 0xa5, bytes, stream));
  CHECK(cudaMemsetAsync(dst, 0, bytes, stream));

  float ms;
  CHECK(benchmark_ms(stream, seconds, [&] {
    return cudaMemcpyAsync(dst, src, bytes, cudaMemcpyDeviceToDevice, stream);
  }, ms));

  std::vector<unsigned char> result(bytes);
  CHECK(cudaMemcpy(result.data(), dst, bytes, cudaMemcpyDeviceToHost));
  EXPECT(std::all_of(result.begin(), result.end(),
                     [](unsigned char value) { return value == 0xa5; }));
  CHECK(cudaFree(dst));
  CHECK(cudaFree(src));
  std::printf("Device-to-device copy (32 MiB): %.3f ms, %.2f GB/s\n",
              ms, bytes / (ms * 1e6));
  return 0;
}

template <typename T, typename Gemm>
int benchmark_gemm(cudaStream_t stream, int seconds, Gemm gemm,
                   const char *name) {
  constexpr int n = 1024;
  constexpr size_t elements = size_t(n) * n;
  constexpr size_t bytes = elements * sizeof(T);
  const T one(1.0f), zero(0.0f), two(2.0f);
  cublasHandle_t handle;
  T *a, *b, *c;
  CHECK(cublasCreate(&handle));
  CHECK(cublasSetStream(handle, stream));
  CHECK(cudaMalloc((void **)&a, bytes));
  CHECK(cudaMalloc((void **)&b, bytes));
  CHECK(cudaMalloc((void **)&c, bytes));
  std::vector<T> values(elements, one);
  CHECK(cudaMemcpy(a, values.data(), bytes, cudaMemcpyHostToDevice));
  std::fill(values.begin(), values.end(), two);
  CHECK(cudaMemcpy(b, values.data(), bytes, cudaMemcpyHostToDevice));

  float ms;
  CHECK(benchmark_ms(stream, seconds, [&] {
    return gemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, n, n, n,
                &one, a, n, b, n, &zero, c, n);
  }, ms));

  CHECK(cudaMemcpy(values.data(), c, bytes, cudaMemcpyDeviceToHost));
  EXPECT(std::all_of(values.begin(), values.end(),
                     [](T value) { return static_cast<float>(value) == 2.0f * n; }));
  CHECK(cudaFree(c));
  CHECK(cudaFree(b));
  CHECK(cudaFree(a));
  CHECK(cublasDestroy(handle));
  std::printf("cuBLAS %s (%d x %d): %.3f ms, %.2f GFLOP/s\n",
              name, n, n, ms, 2.0 * n * n * n / (ms * 1e6));
  return 0;
}

int benchmark_fft(cudaStream_t stream, int seconds) {
  constexpr int n = 4096, batch = 64;
  std::vector<cufftComplex> values(n * batch);
  for (int i = 0; i < batch; ++i)
    values[i * n].x = 1.0f;
  const size_t bytes = values.size() * sizeof(values[0]);
  cufftComplex *input, *output;
  cufftHandle plan;
  CHECK(cudaMalloc(&input, bytes));
  CHECK(cudaMalloc(&output, bytes));
  CHECK(cudaMemcpy(input, values.data(), bytes, cudaMemcpyHostToDevice));
  CHECK(cufftPlan1d(&plan, n, CUFFT_C2C, batch));
  CHECK(cufftSetStream(plan, stream));

  float ms;
  CHECK(benchmark_ms(stream, seconds, [&] {
    return cufftExecC2C(plan, input, output, CUFFT_FORWARD);
  }, ms));

  CHECK(cudaMemcpy(values.data(), output, bytes, cudaMemcpyDeviceToHost));
  EXPECT(std::all_of(values.begin(), values.end(), [](cufftComplex value) {
    return std::fabs(value.x - 1.0f) < 1e-5f && std::fabs(value.y) < 1e-5f;
  }));
  CHECK(cufftDestroy(plan));
  CHECK(cudaFree(output));
  CHECK(cudaFree(input));
  std::printf("cuFFT C2C (%d x %d): %.3f ms/batch, %.0f transforms/s\n",
              batch, n, ms, batch * 1000.0 / ms);
  return 0;
}

int benchmark_rng(cudaStream_t stream, int seconds) {
  constexpr size_t count = 1 << 20;
  curandGenerator_t generator;
  float *output;
  CHECK(cudaMalloc(&output, count * sizeof(float)));
  CHECK(curandCreateGenerator(&generator, CURAND_RNG_PSEUDO_DEFAULT));
  CHECK(curandSetPseudoRandomGeneratorSeed(generator, 1234));
  CHECK(curandSetStream(generator, stream));

  float ms;
  CHECK(benchmark_ms(stream, seconds, [&] {
    return curandGenerateUniform(generator, output, count);
  }, ms));

  std::vector<float> values(count);
  CHECK(cudaMemcpy(values.data(), output, count * sizeof(float),
                   cudaMemcpyDeviceToHost));
  double sum = 0;
  for (float value : values) {
    EXPECT(value > 0.0f && value <= 1.0f);
    sum += value;
  }
  EXPECT(std::fabs(sum / count - 0.5) < 0.01);
  CHECK(curandDestroyGenerator(generator));
  CHECK(cudaFree(output));
  std::printf("cuRAND uniform FP32 (%zu values): %.3f ms, %.2f Gvalues/s\n",
              count, ms, count / (ms * 1e6));
  return 0;
}

int benchmark_cholesky(cudaStream_t stream, int seconds) {
  constexpr int n = 512;
  constexpr size_t elements = size_t(n) * n, bytes = elements * sizeof(float);
  // I + 0.25 J is dense and positive definite. POTRF overwrites its input.
  std::vector<float> original(elements, 0.25f);
  for (int i = 0; i < n; ++i)
    original[i * (n + 1)] += 1.0f;
  cusolverDnHandle_t handle;
  float *reference, *matrices, *workspace;
  int *info, workspace_elements;
  CHECK(cusolverDnCreate(&handle));
  CHECK(cusolverDnSetStream(handle, stream));
  CHECK(cudaMalloc(&reference, bytes));
  CHECK(cudaMalloc(&matrices, benchmark_iterations * bytes));
  CHECK(cudaMalloc(&info, benchmark_iterations * sizeof(int)));
  CHECK(cudaMemcpy(reference, original.data(), bytes, cudaMemcpyHostToDevice));
  CHECK(cusolverDnSpotrf_bufferSize(handle, CUBLAS_FILL_MODE_LOWER, n,
                                  matrices, n, &workspace_elements));
  CHECK(cudaMalloc(&workspace, workspace_elements * sizeof(float)));

  float ms;
  CHECK(benchmark_ms(stream, seconds, [&](int i) {
    return cusolverDnSpotrf(handle, CUBLAS_FILL_MODE_LOWER, n,
                          matrices + i * elements, n, workspace,
                          workspace_elements, info + i);
  }, [&] {
    for (int i = 0; i < benchmark_iterations; ++i)
      CHECK(cudaMemcpyAsync(matrices + i * elements, reference, bytes,
                            cudaMemcpyDeviceToDevice, stream));
    return 0;
  }, ms));

  int statuses[benchmark_iterations];
  CHECK(cudaMemcpy(statuses, info, sizeof(statuses), cudaMemcpyDeviceToHost));
  EXPECT(std::all_of(statuses, statuses + benchmark_iterations,
                     [](int value) { return value == 0; }));
  std::vector<float> factor(elements);
  CHECK(cudaMemcpy(factor.data(), matrices, bytes, cudaMemcpyDeviceToHost));
  for (int i = 0; i < n; ++i)
    for (int j = 0; j <= i; ++j) {
      double value = 0;
      for (int k = 0; k <= j; ++k)
        value += double(factor[i + k * n]) * factor[j + k * n];
      EXPECT(std::fabs(value - original[i + j * n]) < 1e-4);
    }
  CHECK(cudaFree(info));
  CHECK(cudaFree(workspace));
  CHECK(cudaFree(matrices));
  CHECK(cudaFree(reference));
  CHECK(cusolverDnDestroy(handle));
  std::printf("cuSOLVER FP32 Cholesky (%d x %d): %.3f ms, %.2f GFLOP/s\n",
              n, n, ms, (double(n) * n * n / 3) / (ms * 1e6));
  return 0;
}

int benchmark_spmv(cudaStream_t stream, int seconds) {
  constexpr int n = 1 << 18, per_row = 7, nnz = n * per_row;
  constexpr size_t vector_bytes = n * sizeof(float);
  const float one = 1.0f, zero = 0.0f;
  std::vector<int> host_rows(n + 1), host_cols(nnz);
  for (int i = 0; i <= n; ++i)
    host_rows[i] = i * per_row;
  for (int i = 0; i < n; ++i)
    for (int j = 0; j < per_row; ++j)
      host_cols[i * per_row + j] = (i + j * 257) % n;
  std::vector<float> host_values(nnz, 1.0f), host_vector(n, 2.0f);
  cusparseHandle_t handle;
  cusparseSpMatDescr_t matrix;
  cusparseDnVecDescr_t input, output;
  int *rows, *cols;
  float *values, *x, *y;
  CHECK(cusparseCreate(&handle));
  CHECK(cusparseSetStream(handle, stream));
  CHECK(cudaMalloc(&rows, host_rows.size() * sizeof(int)));
  CHECK(cudaMalloc(&cols, host_cols.size() * sizeof(int)));
  CHECK(cudaMalloc(&values, host_values.size() * sizeof(float)));
  CHECK(cudaMalloc(&x, vector_bytes));
  CHECK(cudaMalloc(&y, vector_bytes));
  CHECK(cudaMemcpy(rows, host_rows.data(), host_rows.size() * sizeof(int),
                   cudaMemcpyHostToDevice));
  CHECK(cudaMemcpy(cols, host_cols.data(), host_cols.size() * sizeof(int),
                   cudaMemcpyHostToDevice));
  CHECK(cudaMemcpy(values, host_values.data(), host_values.size() * sizeof(float),
                   cudaMemcpyHostToDevice));
  CHECK(cudaMemcpy(x, host_vector.data(), vector_bytes, cudaMemcpyHostToDevice));
  CHECK(cusparseCreateCsr(&matrix, n, n, nnz, rows, cols, values,
                          CUSPARSE_INDEX_32I, CUSPARSE_INDEX_32I,
                          CUSPARSE_INDEX_BASE_ZERO, CUDA_R_32F));
  CHECK(cusparseCreateDnVec(&input, n, x, CUDA_R_32F));
  CHECK(cusparseCreateDnVec(&output, n, y, CUDA_R_32F));
  size_t bytes;
  void *buffer = nullptr;
  constexpr auto op = CUSPARSE_OPERATION_NON_TRANSPOSE;
  constexpr auto algorithm = CUSPARSE_SPMV_ALG_DEFAULT;
  CHECK(cusparseSpMV_bufferSize(handle, op, &one, matrix, input, &zero,
                                output, CUDA_R_32F, algorithm, &bytes));
  if (bytes)
    CHECK(cudaMalloc(&buffer, bytes));

  float ms;
  CHECK(benchmark_ms(stream, seconds, [&] {
    return cusparseSpMV(handle, op, &one, matrix, input, &zero, output,
                       CUDA_R_32F, algorithm, buffer);
  }, ms));

  CHECK(cudaMemcpy(host_vector.data(), y, vector_bytes, cudaMemcpyDeviceToHost));
  EXPECT(std::all_of(host_vector.begin(), host_vector.end(),
                     [](float value) { return value == 2 * per_row; }));
  CHECK(cusparseDestroyDnVec(output));
  CHECK(cusparseDestroyDnVec(input));
  CHECK(cusparseDestroySpMat(matrix));
  CHECK(cusparseDestroy(handle));
  CHECK(cudaFree(buffer));
  CHECK(cudaFree(y));
  CHECK(cudaFree(x));
  CHECK(cudaFree(values));
  CHECK(cudaFree(cols));
  CHECK(cudaFree(rows));
  std::printf("cuSPARSE CSR SpMV (%d nonzeros): %.3f ms, %.2f Gnonzeros/s\n",
              nnz, ms, nnz / (ms * 1e6));
  return 0;
}

int benchmark_nvrtc(int seconds) {
  const char *source = R"(
    extern "C" __global__ void saxpy(float *y, const float *x, float a, int n) {
      int i = blockIdx.x * blockDim.x + threadIdx.x;
      if (i < n) y[i] = a * x[i] + y[i];
    }
  )";
  const char *options[] = {"--gpu-architecture=sm_53"};
  // The first compilation loads NVRTC's compiler. Time only later compiles.
  auto compile = [&](double &ms) {
    nvrtcProgram program;
    CHECK(nvrtcCreateProgram(&program, source, "saxpy.cu", 0, nullptr, nullptr));
    auto start = BenchmarkClock::now();
    nvrtcResult status = nvrtcCompileProgram(program, 1, options);
    ms = std::chrono::duration<double, std::milli>(BenchmarkClock::now() - start).count();
    size_t cubin_size = 0;
    if (status == NVRTC_SUCCESS)
      status = nvrtcGetCUBINSize(program, &cubin_size);
    CHECK(nvrtcDestroyProgram(&program));
    CHECK(status);
    EXPECT(cubin_size > 0 && ms > 0);
    return 0;
  };
  double warmup_ms;
  CHECK(compile(warmup_ms));
  std::vector<double> timings;
  auto deadline = BenchmarkClock::now() + std::chrono::seconds(seconds);
  do {
    double ms;
    CHECK(compile(ms));
    timings.push_back(ms);
  } while (timings.size() < 5 || BenchmarkClock::now() < deadline);
  std::sort(timings.begin(), timings.end());
  std::printf("NVRTC SAXPY compilation (SM 5.3): %.2f ms median (%zu compiles)\n",
              timings[timings.size() / 2], timings.size());
  return 0;
}

// The cuDNN 8 and 9 legacy convolution ABIs share these opaque handles.
// Load this small API surface at runtime so the other probes need no cuDNN SDK.
namespace cudnn_abi {
struct Context;
struct Tensor;
struct Filter;
struct Convolution;
enum DataType { Float = 0, Half = 2 };
enum Format { NCHW = 0 };
enum Mode { CrossCorrelation = 1 };
enum Algorithm { ImplicitGemm = 0 };
}

int benchmark_cudnn(cudaStream_t stream, int seconds) {
  using namespace cudnn_abi;
  void *library = dlopen("libcudnn.so.9", RTLD_NOW | RTLD_LOCAL);
  if (!library)
    library = dlopen("libcudnn.so.8", RTLD_NOW | RTLD_LOCAL);
  if (!library) {
    const char *error = dlerror();
    if (std::getenv("DEBIAN_TEGRA_REQUIRE_CUDNN")) {
      std::fprintf(stderr, "Cannot load cuDNN 8 or 9: %s\n", error);
      return 1;
    }
    std::printf("SKIP cuDNN: no loadable cuDNN 8 or 9 runtime (%s)\n", error);
    return 0;
  }
  std::unique_ptr<void, decltype(&dlclose)> guard(library, dlclose);

#define LOAD_CUDNN(name, result, ...) \
  auto name = reinterpret_cast<result (*)(__VA_ARGS__)>(dlsym(library, #name)); \
  EXPECT(name != nullptr)
  LOAD_CUDNN(cudnnGetVersion, size_t);
  LOAD_CUDNN(cudnnGetErrorString, const char *, int);
  LOAD_CUDNN(cudnnCreate, int, Context **);
  LOAD_CUDNN(cudnnDestroy, int, Context *);
  LOAD_CUDNN(cudnnSetStream, int, Context *, cudaStream_t);
  LOAD_CUDNN(cudnnCreateTensorDescriptor, int, Tensor **);
  LOAD_CUDNN(cudnnDestroyTensorDescriptor, int, Tensor *);
  LOAD_CUDNN(cudnnSetTensor4dDescriptor, int, Tensor *, Format, DataType,
             int, int, int, int);
  LOAD_CUDNN(cudnnCreateFilterDescriptor, int, Filter **);
  LOAD_CUDNN(cudnnDestroyFilterDescriptor, int, Filter *);
  LOAD_CUDNN(cudnnSetFilter4dDescriptor, int, Filter *, DataType, Format,
             int, int, int, int);
  LOAD_CUDNN(cudnnCreateConvolutionDescriptor, int, Convolution **);
  LOAD_CUDNN(cudnnDestroyConvolutionDescriptor, int, Convolution *);
  LOAD_CUDNN(cudnnSetConvolution2dDescriptor, int, Convolution *,
             int, int, int, int, int, int, Mode, DataType);
  LOAD_CUDNN(cudnnGetConvolutionForwardWorkspaceSize, int, Context *,
             const Tensor *, const Filter *, const Convolution *,
             const Tensor *, Algorithm, size_t *);
  LOAD_CUDNN(cudnnConvolutionForward, int, Context *, const void *,
             const Tensor *, const void *, const Filter *, const void *,
             const Convolution *, Algorithm, void *, size_t, const void *,
             const Tensor *, void *);
#undef LOAD_CUDNN

  auto check_cudnn = [&](int status) {
    if (status)
      std::fprintf(stderr, "cuDNN %zu: %s\n", cudnnGetVersion(),
                   cudnnGetErrorString(status));
    return status;
  };
  constexpr int channels = 32, width = 64, filter_size = 3;
  constexpr int output_width = width - filter_size + 1;
  constexpr size_t input_count = channels * width * width;
  constexpr size_t filter_count = channels * channels * filter_size * filter_size;
  constexpr size_t output_count = channels * output_width * output_width;
  auto run = [&](auto input_value, DataType type, const char *precision) {
    using T = decltype(input_value);
    Context *handle;
    Tensor *input, *output;
    Filter *filter;
    Convolution *conv;
    T *x, *w, *y;
    CHECK(check_cudnn(cudnnCreate(&handle)));
    CHECK(check_cudnn(cudnnSetStream(handle, stream)));
    CHECK(check_cudnn(cudnnCreateTensorDescriptor(&input)));
    CHECK(check_cudnn(cudnnCreateTensorDescriptor(&output)));
    CHECK(check_cudnn(cudnnSetTensor4dDescriptor(input, NCHW, type,
                                               1, channels, width, width)));
    CHECK(check_cudnn(cudnnSetTensor4dDescriptor(output, NCHW, type, 1, channels,
                                               output_width, output_width)));
    CHECK(check_cudnn(cudnnCreateFilterDescriptor(&filter)));
    CHECK(check_cudnn(cudnnSetFilter4dDescriptor(filter, type, NCHW, channels,
                                               channels, filter_size, filter_size)));
    CHECK(check_cudnn(cudnnCreateConvolutionDescriptor(&conv)));
    CHECK(check_cudnn(cudnnSetConvolution2dDescriptor(conv, 0, 0, 1, 1, 1, 1,
                                                    CrossCorrelation, type)));
    size_t bytes;
    void *workspace = nullptr;
    CHECK(check_cudnn(cudnnGetConvolutionForwardWorkspaceSize(
        handle, input, filter, conv, output, ImplicitGemm, &bytes)));
    if (bytes)
      CHECK(cudaMalloc(&workspace, bytes));
    CHECK(cudaMalloc(&x, input_count * sizeof(T)));
    CHECK(cudaMalloc(&w, filter_count * sizeof(T)));
    CHECK(cudaMalloc(&y, output_count * sizeof(T)));
    std::vector<T> values(input_count, input_value), weights(filter_count, T(2.0f));
    CHECK(cudaMemcpy(x, values.data(), input_count * sizeof(T), cudaMemcpyHostToDevice));
    CHECK(cudaMemcpy(w, weights.data(), filter_count * sizeof(T), cudaMemcpyHostToDevice));

    const float one = 1.0f, zero = 0.0f;
    float ms;
    CHECK(benchmark_ms(stream, seconds, [&] {
      return check_cudnn(cudnnConvolutionForward(
          handle, &one, input, x, filter, w, conv, ImplicitGemm, workspace,
          bytes, &zero, output, y));
    }, ms));

    CHECK(cudaMemcpy(values.data(), y, output_count * sizeof(T), cudaMemcpyDeviceToHost));
    constexpr int products = channels * filter_size * filter_size;
    EXPECT(std::all_of(values.begin(), values.begin() + output_count,
                       [](T value) { return static_cast<float>(value) == 2.0f * products; }));
    CHECK(cudaFree(y));
    CHECK(cudaFree(w));
    CHECK(cudaFree(x));
    CHECK(cudaFree(workspace));
    CHECK(check_cudnn(cudnnDestroyConvolutionDescriptor(conv)));
    CHECK(check_cudnn(cudnnDestroyFilterDescriptor(filter)));
    CHECK(check_cudnn(cudnnDestroyTensorDescriptor(output)));
    CHECK(check_cudnn(cudnnDestroyTensorDescriptor(input)));
    CHECK(check_cudnn(cudnnDestroy(handle)));
    std::printf("cuDNN %zu %s convolution (1x32x64x64, 32 3x3 filters): "
                "%.3f ms, %.2f GFLOP/s\n", cudnnGetVersion(), precision, ms,
                2.0 * output_count * products / (ms * 1e6));
    return 0;
  };

  // The cuDNN scaling factors are float for both FP32 and FP16 tensors.
  CHECK(run(1.0f, Float, "FP32"));
  CHECK(run(__half(1.0f), Half, "FP16"));
  return 0;
}

int cuda_benchmark(int seconds) {
  std::setvbuf(stdout, nullptr, _IOLBF, 0);
  cudaDeviceProp device;
  cudaStream_t stream;
  CHECK(cudaSetDevice(0));
  CHECK(cudaGetDeviceProperties(&device, 0));
  CHECK(cudaStreamCreate(&stream));
  std::printf("GPU: %s (SM %d.%d)\n", device.name, device.major, device.minor);
  if (seconds)
    std::printf("Minimum run time: %d seconds per workload\n", seconds);
  CHECK(benchmark_copy(stream, seconds));
  CHECK(benchmark_gemm<float>(stream, seconds, cublasSgemm, "FP32 SGEMM"));
  CHECK(benchmark_gemm<__half>(stream, seconds, cublasHgemm, "FP16 HGEMM"));
  CHECK(benchmark_fft(stream, seconds));
  CHECK(benchmark_rng(stream, seconds));
  CHECK(benchmark_cholesky(stream, seconds));
  CHECK(benchmark_spmv(stream, seconds));
  CHECK(benchmark_cudnn(stream, seconds));
  CHECK(cudaStreamDestroy(stream));
  CHECK(benchmark_nvrtc(seconds));
  return 0;
}

int main(int argc, char **argv) {
  if (argc >= 2 && argc <= 3 && std::strcmp(argv[1], "benchmark") == 0) {
    long seconds = 0;
    if (argc == 3) {
      char *end;
      seconds = std::strtol(argv[2], &end, 10);
      if (end == argv[2] || *end || seconds < 0 || seconds > 3600) {
        std::fprintf(stderr, "Benchmark seconds must be an integer from 0 to 3600\n");
        return 2;
      }
    }
    return cuda_benchmark(static_cast<int>(seconds));
  }
  if (argc != 2) {
    std::fprintf(stderr, "usage: cuda-probes {cuda|cublas|cufft|curand|cusolver|cusparse|nvrtc} or benchmark [seconds]\n");
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
