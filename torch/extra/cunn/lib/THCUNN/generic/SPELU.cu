#ifndef THC_GENERIC_FILE
#define THC_GENERIC_FILE "generic/SPELU.cu"
#else

void THNN_(SPELU_updateOutput)(
           THCState *state,
           THCTensor *input,
           THCTensor *output,
           THCTensor *weight,
           long nOutputPlane)
{
  THCTensor_(resizeAs)(state, output, input);

  real *w = THCTensor_(data)(state, weight);

  if (nOutputPlane == 0)
  {
    THC_pointwiseApply2(state, output, input, SPELUUpdateOutput<real>(w));
  }
  else
  {
    int ndim = THCTensor_(nDimension)(state, input);
    input = THCTensor_(newContiguous)(state, input);

    int n = THCTensor_(nElement)(state, input);
    int mapSize = 1;
    if (ndim == 3)
      mapSize = (input->size[1] * input->size[2]);
    else if (ndim == 4)
      mapSize = (input->size[2] * input->size[3]);
    int nElemsPerSample = nOutputPlane * mapSize;
    speluForward<<<GET_BLOCKS(n), CUDA_NUM_THREADS, 0, THCState_getCurrentStream(state)>>>(
      THCTensor_(data)(state, output),
      THCTensor_(data)(state, input),
      w,
      n, nElemsPerSample, mapSize
    );
    THCudaCheck(cudaGetLastError());
    THCTensor_(free)(state, input);
  }
}

void THNN_(SPELU_updateGradInput)(
           THCState *state,
           THCTensor *input,
           THCTensor *gradOutput,
           THCTensor *gradInput,
           THCTensor *weight,
           long nOutputPlane)
{
  THCUNN_check_nElement(state, input, gradOutput);
  THCTensor_(resizeAs)(state, gradInput, input);

  real *w = THCTensor_(data)(state, weight);
  if (nOutputPlane == 0)
  {
    THC_pointwiseApply3(state, gradInput, gradOutput, input, SPELUUpdateGradInput<real>(w));
  }
  else
  {
    int ndim = THCTensor_(nDimension)(state, input);
    input = THCTensor_(newContiguous)(state, input);
    gradOutput = THCTensor_(newContiguous)(state, gradOutput);

    int n = THCTensor_(nElement)(state, input);
    int mapSize = 1;
    if (ndim == 3)
      mapSize = (input->size[1] * input->size[2]);
    else if (ndim == 4)
      mapSize = (input->size[2] * input->size[3]);
    int nElemsPerSample = nOutputPlane * mapSize;
    speluBackward<<<GET_BLOCKS(n), CUDA_NUM_THREADS, 0, THCState_getCurrentStream(state)>>>(
      THCTensor_(data)(state, gradInput),
      THCTensor_(data)(state, input),
      w,
      THCTensor_(data)(state, gradOutput),
      n, nElemsPerSample, mapSize
    );
    THCudaCheck(cudaGetLastError());
    THCTensor_(free)(state, input);
    THCTensor_(free)(state, gradOutput);
  }
}

void THNN_(SPELU_accGradParameters)(
           THCState *state,
           THCTensor *input,
           THCTensor *gradOutput,
           THCTensor *gradInput,
           THCTensor *weight,
           THCTensor *gradWeight,
           THCTensor *gradWeightBuf,
           THCTensor *gradWeightBuf2,
           long nOutputPlane,
           real scale)
{
  THCUNN_check_nElement(state, input, gradOutput);
  // use grad input for temporary storage, then call updateGradInput again

  if (nOutputPlane == 0)
  {
    THC_pointwiseApply3(state, gradInput, input, gradOutput, SPELUAccGradParametersShared<real>());

    // introduces a sync point
    real sum = ScalarConvert<accreal, real>::to(THCTensor_(sumall)(state, gradInput));
    real w = THCTensor_(get1d)(state, gradWeight, 0);
    THCTensor_(set1d)(state, gradWeight, 0, w + sum * scale);

    // restore gradInput
    THNN_(SPELU_updateGradInput)(state, input, gradOutput, gradInput, weight, nOutputPlane);
  }
  else
  {
    int ndim = THCTensor_(nDimension)(state, input);

    if (ndim == 1)
    {
      THC_pointwiseApply3(state, gradWeight, input, gradOutput, SPELUAccGradParameters1to1<real>(scale));
    }
    else
    {
      THC_pointwiseApply3(state, gradInput, input, gradOutput, SPELUAccGradParameters<real>(scale));
      THCTensor *sumbuf = gradWeightBuf2;
      THCTensor_(resizeAs)(state, gradWeightBuf, gradWeight);

      if (ndim == 2)
      {
        THCTensor_(sum)(state, gradWeightBuf, gradInput, 0);
        THCTensor_(cadd)(state, gradWeight, gradWeight, scale, gradWeightBuf);
      }
      else if (ndim == 3)
      {
        THCTensor *buffer = THCTensor_(newContiguous)(state, gradInput);
        THCTensor_(resize2d)(state, buffer, nOutputPlane, input->size[1] * input->size[2]);
        THCTensor_(sum)(state, gradWeightBuf, buffer, 1);
        THCTensor_(cadd)(state, gradWeight, gradWeight, scale, gradWeightBuf);
        THCTensor_(free)(state, buffer);
      }
      else if (ndim == 4)
      {
        THCTensor *buffer = THCTensor_(newContiguous)(state, gradInput);
        THCTensor_(resize3d)(state, buffer, input->size[0], nOutputPlane, input->size[2] * input->size[3]);
        THCTensor_(resize2d)(state, sumbuf, input->size[0], nOutputPlane);
        THCTensor_(sum)(state, sumbuf, buffer, 2);
        THCTensor_(sum)(state, gradWeightBuf, sumbuf, 0);
        THCTensor_(cadd)(state, gradWeight, gradWeight, scale, gradWeightBuf);
        THCTensor_(free)(state, buffer);
      }

      // restore gradInput
      THNN_(SPELU_updateGradInput)(state, input, gradOutput, gradInput, weight, nOutputPlane);
    }
  }
}

#endif
