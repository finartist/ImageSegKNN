#pragma once
#include "header/cuda_util.h"
#include <cuda_runtime.h>
#include <cuda.h>
#include "header/cuda_KNN.cuh"
#include "header/cuda_MinHeap.cuh"
#include "header/ppma_io.hpp"
#include <algorithm>

// to compile a header into this main, you have to set 
//Configuration Properties -> CUDA C/C++ -> Common -> Generate Relocatable Device Code -> Yes (-rdc=true)

__host__ KNN<3>* MirrorTestKNN()
{
	float* labelColors = (float*)malloc(sizeof(float) * 3 * 3);
	float* red = RgbLab::MakeColor(255, 0, 0);
	float* green = RgbLab::MakeColor(0, 255, 0);
	float* blue = RgbLab::MakeColor(0, 0, 255);

	for (int i = 0; i < 3; ++i)
	{
		labelColors[0 * 3 + i] = red[i];
		labelColors[1 * 3 + i] = green[i];
		labelColors[2 * 3 + i] = blue[i];
	}

	int numColorsPerLabel = 8;

	KNN<3>* knn = new KNN<3>(labelColors);

	float** label1colors = (float**)malloc(sizeof(float*) * numColorsPerLabel);
	float** label2colors = (float**)malloc(sizeof(float*) * numColorsPerLabel);
	float** label3colors = (float**)malloc(sizeof(float*) * numColorsPerLabel);

	label2colors[0] = RgbLab::MakeColor(255, 255, 255);
	label2colors[1] = RgbLab::MakeColor(250, 250, 250);
	label2colors[2] = RgbLab::MakeColor(162, 163, 168);
	label2colors[3] = RgbLab::MakeColor(216, 211, 207);

	label3colors[0] = RgbLab::MakeColor(83, 145, 255);
	label3colors[1] = RgbLab::MakeColor(104, 182, 255);
	label3colors[2] = RgbLab::MakeColor(173, 125, 89);
	label3colors[3] = RgbLab::MakeColor(248, 194, 150);

	label1colors[0] = RgbLab::MakeColor(254, 254, 156);
	label1colors[1] = RgbLab::MakeColor(226, 77, 21);
	label1colors[2] = RgbLab::MakeColor(255, 164, 43);
	label1colors[3] = RgbLab::MakeColor(159, 65, 4);

	knn->AddColorsToTrainingsset(label1colors, 0, 4);
	knn->AddColorsToTrainingsset(label2colors, 1, 4);
	knn->AddColorsToTrainingsset(label3colors, 2, 4);

	return knn;
}

__device__ int getIndexInTrainingssset(int label, int index, int numColorsPerLabel)
{
	return label * numColorsPerLabel * 3 + index * 3;
}

__global__ void KNNRgb(float* picturedata, int numPixels, int k, int labelCount, float* labelColors, float* trainingsSet, int* trainingsEntryCount, int numColorsPerlabel, int numTrainingsEntries) {

	int gtid = blockDim.x * blockIdx.x + threadIdx.x;

	if(gtid >= numPixels)
	{
		return;
	}

	NeighbourEntry* neighbour_entry = (NeighbourEntry*) malloc(sizeof(NeighbourEntry) * k);
	for(int i = 0; i < k; ++i)
	{
		neighbour_entry[i] = NeighbourEntry(10000, 0);
	}
	
	//avoid false results by using at max the amount of trainingsentries
	int newk = k;
	if (numTrainingsEntries < newk)
	{
		newk = numTrainingsEntries;
	}

	float* voteCount = (float*) malloc(sizeof(float) * labelCount);
	for(int i = 0; i < labelCount; ++i)
	{
		voteCount[i] = 0;
	}
	voteCount[0] = 1.0f / 10000.0f * newk;

	for(int i = 0; i < labelCount; ++i)
	{
		for (int j = 0; j < trainingsEntryCount[i]; ++j)
		{
			// get the distance
			float length = RgbLab::ColorDistance(&picturedata[gtid*3], &trainingsSet[getIndexInTrainingssset(i, j, numColorsPerlabel)]);
			for (int l = 0; l < newk; ++l)
			{
				// if we find something closer than the latest k nearest
				// update our list
				if (length < neighbour_entry[l].distance)
				{
					// update the votes
					voteCount[i] += 1.0 / (length + 0.0000001);
					voteCount[neighbour_entry[newk - 1].label] -= 1.0 / neighbour_entry[newk - 1].distance;

					// therefore we have to insert the new and push the ones behind it one index further (aka copy them)
					for (int m = newk - 2; m > l; --m)
					{
						neighbour_entry[m + 1] = neighbour_entry[m];
					}

					neighbour_entry[l] = NeighbourEntry((length + 0.0000001), i);

					break;
				}
			}
		}
	}

	// determine the right label based on votes
	float maxVote = 0;
	int winningLabel = 0;

	for (int i = 0; i < labelCount; ++i)
	{
		if (maxVote < voteCount[i])
		{
			maxVote = voteCount[i];
			winningLabel = i;
		}
	}

	for(int i = 0; i < 3; ++i)
	{
		picturedata[gtid * 3 + i] = labelColors[winningLabel * 3 + i];
	}

	free(voteCount);
	free(neighbour_entry);
}

void main()
{
	// get number of CUDA devices
	int deviceCount = 0;
	cudaGetDeviceCount(&deviceCount);
	std::cerr << deviceCount << std::endl;

	// set the device
	cudaSetDevice(0);
	
	// query the device properties
	cudaDeviceProp props;
	cudaGetDeviceProperties(&props, 0);

	std::string file = "images/MirrorsEdgeTest.ppm";
	int xsize = 0;
	int ysize = 0;
	int maxrgb = 0;

	const int labelcount = 3;
	KNN<labelcount> knn = *MirrorTestKNN();

	int* r;
	int* g;
	int* b;

	ppma_read(file, xsize, ysize, maxrgb, &r, &g, &b);

	int numPixels = xsize * ysize;

	float* host_picturedata = (float*)malloc(sizeof(float) * numPixels * 3);
	for(int i = 0; i < numPixels; ++i)
	{
		host_picturedata[3*i] = r[i] / 255.0f;
		host_picturedata[3*i + 1] = g[i] / 255.0f;
		host_picturedata[3*i + 2] = b[i] / 255.0f;
	}

	float* res = (float*)malloc(sizeof(float) * numPixels * 3);

	float* device_picturedata;
	checkErrorsCuda(cudaMalloc((void**)&device_picturedata, sizeof(float) * numPixels * 3));
	checkErrorsCuda(cudaMemcpy(device_picturedata, host_picturedata, sizeof(float) * numPixels * 3, cudaMemcpyHostToDevice));
	float* device_labelColors;
	checkErrorsCuda(cudaMalloc((void**) &device_labelColors, knn.GetSizeOfLabelColors()));
	checkErrorsCuda(cudaMemcpy(device_labelColors, knn.GetLabelColors(), knn.GetSizeOfLabelColors(), cudaMemcpyHostToDevice));
	float* device_trainingsSet;
	checkErrorsCuda(cudaMalloc((void**) &device_trainingsSet, knn.GetSizeOfTrainingsset()));
	checkErrorsCuda(cudaMemcpy(device_trainingsSet, knn.GetTrainingsSet(), knn.GetSizeOfTrainingsset(), cudaMemcpyHostToDevice));
	int* device_trainingsEntryCount;
	checkErrorsCuda(cudaMalloc((void**)&device_trainingsEntryCount, knn.GetSizeOfTrainingsSetCount()));
	checkErrorsCuda(cudaMemcpy(device_trainingsEntryCount, knn.GetTrainingsSetCount(), knn.GetSizeOfTrainingsSetCount(), cudaMemcpyHostToDevice));

	// determine thread layout
	const int max_threads_per_block = props.maxThreadsPerBlock;
	int num_blocks = (numPixels) / max_threads_per_block;
	if ((numPixels) % max_threads_per_block != 0)
	{
		num_blocks++;
	}
	int num_threads_per_block = std::min(numPixels, max_threads_per_block);

	int k = 5;
	KNNRgb << <num_blocks, num_threads_per_block >> > (device_picturedata, numPixels, k, labelcount, device_labelColors, device_trainingsSet, device_trainingsEntryCount, knn.GetNumColorsPerLabel(), knn.GetNumTrainingsEntries());
	
	checkErrorsCuda(cudaDeviceSynchronize());
	checkLastCudaError("kernel execution failed");

	checkErrorsCuda(cudaMemcpy(res, device_picturedata, sizeof(float) * numPixels * 3, cudaMemcpyDeviceToHost));
	//cudaDeviceSynchronize();

	for (int i = 0; i < numPixels; ++i)
	{
		r[i] = (int) (res[3*i] * 255);
		g[i] = (int) (res[3*i + 1] * 255);
		b[i] = (int) (res[3*i + 2] * 255);
	}

	ppma_write("images/MirrorsEdgeTestSeg.ppm", xsize, ysize, r, g, b);

	printf("ready");

	free(r);
	free(g);
	free(b);
	free(host_picturedata);

	cudaFree(device_picturedata);
	cudaFree(device_labelColors);
	cudaFree(device_trainingsEntryCount);
	cudaFree(device_trainingsSet);
}