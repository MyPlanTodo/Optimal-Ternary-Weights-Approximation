#include <vector>

#include "caffe/filler.hpp"
#include "caffe/layers/ternary_inner_product_layer.hpp"
#include "caffe/util/math_functions.hpp"

namespace caffe {

template <typename Dtype>
__global__ void TernaryWeightQuant(const int n, const int weight_dim, const Dtype* weight,
        const Dtype* threshold, Dtype* ternary_weight) {
  CUDA_KERNEL_LOOP(index, n) {
    int i = index/weight_dim;
    Dtype ternary_code = weight[index] > Dtype(0) ? Dtype(1) : Dtype(-1);
    ternary_weight[index] = fabs(weight[index]) >= threshold[i] ? ternary_code : Dtype(0);
  }
}

template <typename Dtype>
__global__ void TernaryWeightForward(const int n, const int weight_dim, const Dtype* weight,
        const Dtype* alpha, Dtype* ternary_weight) {
  CUDA_KERNEL_LOOP(index, n) {
    int i = index/weight_dim;
    ternary_weight[index] = weight[index] * alpha[i];
  }
}

template <typename Dtype>
void TernaryInnerProductLayer<Dtype>::Forward_gpu(const vector<Blob<Dtype>*>& bottom,
    const vector<Blob<Dtype>*>& top) {
  const Dtype* bottom_data = bottom[0]->gpu_data();
  Dtype* top_data = top[0]->mutable_gpu_data();
  const Dtype* weight = this->blobs_[0]->gpu_data();
  const int weight_dim = this->blobs_[0]->count(1);
  
  if (skip_quantization_ == false) {
    caffe_gpu_abs(this->blobs_[0]->count(), weight, ternary_weights_.mutable_gpu_data());
    caffe_gpu_set(weight_sum_multiplier_.count(),Dtype(1),weight_sum_multiplier_.mutable_gpu_data());
    const int nthreads = this->blobs_[0]->count();
    Dtype* threshold_ptr = threshold_.mutable_cpu_data();

    for (int i = 0; i < this->blobs_[0]->num(); i++) {
        Dtype* kernel_mutable_cpu_data = ternary_weights_.mutable_cpu_data()+i*this->blobs_[0]->count(1);
        std::sort(kernel_mutable_cpu_data, kernel_mutable_cpu_data+this->blobs_[0]->count(1));
        int r = 0;
        Dtype s = 0;
        // Dtype* J = contribution_.mutable_cpu_data();
        Dtype loss_max = Dtype(1e-5);
        int idx = 1;
        for (int j = this->blobs_[0]->count(1)-1; j >=0; j--) {
            s += kernel_mutable_cpu_data[j];  r++;
            const Dtype loss = s*s/r;
            if (loss >= loss_max) {
                loss_max = loss;
                idx = j;
            }
        }
        threshold_ptr[i] = kernel_mutable_cpu_data[idx];
    }

    TernaryWeightQuant<Dtype><<<CAFFE_GET_BLOCKS(nthreads), CAFFE_CUDA_NUM_THREADS>>>(
            nthreads, weight_dim, weight, threshold_.gpu_data(), ternary_weights_.mutable_gpu_data());

    const int output_channel_num = this->blobs_[0]->num();
    const int kernel_dim = this->blobs_[0]->count(1);

    caffe_gpu_mul(output_channel_num*kernel_dim, weight, ternary_weights_.gpu_data(),
                    ternary_weights_.mutable_gpu_diff());
    caffe_gpu_gemv<Dtype>(CblasNoTrans, output_channel_num, kernel_dim, (Dtype)1.,                                                 
                                                        ternary_weights_.gpu_diff(), weight_sum_multiplier_.gpu_data(),
                                (Dtype)0., alphas_.mutable_gpu_data());
    caffe_gpu_mul(output_channel_num*kernel_dim, ternary_weights_.gpu_data(),
                    ternary_weights_.gpu_data(), ternary_weights_.mutable_gpu_diff());
    caffe_gpu_gemv<Dtype>(CblasNoTrans, output_channel_num, kernel_dim,                                                            
                            (Dtype)1., ternary_weights_.gpu_diff(),     weight_sum_multiplier_.gpu_data(),
                                (Dtype)0., alphas_.mutable_gpu_diff());
    caffe_gpu_div(output_channel_num, alphas_.gpu_data(), alphas_.gpu_diff(), alphas_.mutable_gpu_data());

    TernaryWeightForward<Dtype><<<CAFFE_GET_BLOCKS(nthreads), CAFFE_CUDA_NUM_THREADS>>>(
            nthreads, weight_dim, ternary_weights_.gpu_data(), alphas_.gpu_data(), ternary_weights_.mutable_gpu_data());
  }
  skip_quantization_ = this->phase_ == TEST;

  const Dtype* ternary_weights = ternary_weights_.gpu_data();
 
  if (M_ == 1) {
    caffe_gpu_gemv<Dtype>(CblasNoTrans, N_, K_, (Dtype)1.,
                            ternary_weights, bottom_data, (Dtype)0., top_data);
    if (bias_term_)
      caffe_gpu_axpy<Dtype>(N_, bias_multiplier_.cpu_data()[0],
                            this->blobs_[1]->gpu_data(), top_data);
  } else {
    caffe_gpu_gemm<Dtype>(CblasNoTrans,
                          transpose_ ? CblasNoTrans : CblasTrans,
                          M_, N_, K_, (Dtype)1.,
                          bottom_data, ternary_weights, (Dtype)0., top_data);
    if (bias_term_)
      caffe_gpu_gemm<Dtype>(CblasNoTrans, CblasNoTrans, M_, N_, 1, (Dtype)1.,
                            bias_multiplier_.gpu_data(),
                            this->blobs_[1]->gpu_data(), (Dtype)1., top_data);
  }
}

template <typename Dtype>
void TernaryInnerProductLayer<Dtype>::Backward_gpu(const vector<Blob<Dtype>*>& top,
    const vector<bool>& propagate_down,
    const vector<Blob<Dtype>*>& bottom) {
  if (this->param_propagate_down_[0]) {
    const Dtype* top_diff = top[0]->gpu_diff();
    const Dtype* bottom_data = bottom[0]->gpu_data();
    // Gradient with respect to weight
    if (transpose_) {
      caffe_gpu_gemm<Dtype>(CblasTrans, CblasNoTrans,
          K_, N_, M_,
          (Dtype)1., bottom_data, top_diff,
          (Dtype)1., this->blobs_[0]->mutable_gpu_diff());
    } else {
      caffe_gpu_gemm<Dtype>(CblasTrans, CblasNoTrans,
          N_, K_, M_,
          (Dtype)1., top_diff, bottom_data,
          (Dtype)1., this->blobs_[0]->mutable_gpu_diff());
    }
  }
  if (bias_term_ && this->param_propagate_down_[1]) {
    const Dtype* top_diff = top[0]->gpu_diff();
    // Gradient with respect to bias
    caffe_gpu_gemv<Dtype>(CblasTrans, M_, N_, (Dtype)1., top_diff,
        bias_multiplier_.gpu_data(), (Dtype)1.,
        this->blobs_[1]->mutable_gpu_diff());
  }
  if (propagate_down[0]) {
    const Dtype* top_diff = top[0]->gpu_diff();
    // Gradient with respect to bottom data
    if (transpose_) {
      caffe_gpu_gemm<Dtype>(CblasNoTrans, CblasTrans,
          M_, K_, N_,
          (Dtype)1., top_diff, ternary_weights_.gpu_data(),
          (Dtype)0., bottom[0]->mutable_gpu_diff());
    } else {
      caffe_gpu_gemm<Dtype>(CblasNoTrans, CblasNoTrans,
          M_, K_, N_,
         (Dtype)1., top_diff, ternary_weights_.gpu_data(),
         (Dtype)0., bottom[0]->mutable_gpu_diff());
    }
  }
}

INSTANTIATE_LAYER_GPU_FUNCS(TernaryInnerProductLayer);

}  // namespace caffe
