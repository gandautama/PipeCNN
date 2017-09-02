/*
 * ------------------------------------------------------
 *
 *   PipeCNN: An OpenCL-Based FPGA Accelerator for CNNs
 *
 * ------------------------------------------------------
 * Filename:
 *   - conv_pipe.cl
 *
 * Author(s):
 *   - Dong Wang, wangdong@m.bjtu.edu.cn
 *
 * History:
 *   - v2.2 Fixed-point Implementation
 * ------------------------------------
 *
 *   Copyright (C) 2016, Institute of Information Science,
 *   Beijing Jiaotong University. All rights reserved.
 *
 *   Licensed under the Apache License, Version 2.0 (the "License");
 *   you may not use this file except in compliance with the License.
 *   You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 *   Unless required by applicable law or agreed to in writing, software
 *   distributed under the License is distributed on an "AS IS" BASIS,
 *   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *   See the License for the specific language governing permissions and
 *   limitations under the License.
 *
 */

#define USE_ROM 

//#define DEBUG_MEMRD
//#define DEBUG_CONV
//#define DEBUG_POOL
//#define DEBUG_MEMWR
//#define DEBUG_LRN
//#define DEBUG_LRN_OUT

#include "hw_param.cl"
#include "rtl_lib.h"

#pragma OPENCL_EXTENSION cl_altera_channels : enable

// Define the precision of the data-path
typedef char DPTYPE;
typedef int  MACTYPE;

// Vectorized data type
typedef struct {
   DPTYPE data[VEC_SIZE];
} lane_data;

// Combined vec-data type from multiple lane
typedef struct {
   lane_data lane[LANE_NUM];
} channel_vec;

// Combined scalar data type from multiple lane
typedef struct {
   DPTYPE lane[LANE_NUM];
} channel_scal;


channel channel_vec    data_ch    __attribute__((depth(CHN_DEPTH)));
channel channel_vec    weight_ch  __attribute__((depth(CHN_DEPTH)));
channel channel_scal   bias_ch    __attribute__((depth(CHN_DEPTH)));
channel channel_scal   conv_ch    __attribute__((depth(CHN_DEPTH)));
channel channel_scal   pool_ch    __attribute__((depth(CHN_DEPTH)));
channel channel_scal   bypass_ch  __attribute__((depth(CHN_DEPTH)));


// parallel MAC units including (VEC_SIZE-1) multipliers
MACTYPE mac(lane_data input, lane_data weights)
{
	MACTYPE output = MASK_MULT & CZERO;
	
	#pragma unroll
	for(int i=0; i<VEC_SIZE/4; i++){
		output += MASK_MULT & mult_add_fix8bx4(input.data[i*4], weights.data[i*4], input.data[i*4+1], weights.data[i*4+1], input.data[i*4+2], weights.data[i*4+2], input.data[i*4+3], weights.data[i*4+3]);
	}
	return output;
}

DPTYPE pool_max(DPTYPE a_in, DPTYPE b_in)
{
	DPTYPE max_value;
	
	if(a_in >= b_in)
		max_value = a_in;
	else
		max_value = b_in;
	
	return max_value;

}

// Fetch Data from Global Memory
__kernel
void memRead(
			// Params Ports
			uchar  data_dim1,
			uchar  data_dim2,
			uchar  weight_dim1,
			uchar  weight_dim2,
			uchar  stride,
			uchar  padding,
			uchar  split,
			// Data Ports
			__global lane_data    *restrict bottom,
			__global channel_vec  *restrict weights,
			__global channel_scal *restrict bias        )

{
	#ifdef DEBUG_MEMRD
	ushort global_x = get_global_id(0);
	ushort global_y = get_global_id(1);
	uint   global_z = get_global_id(2);
	#endif
	
	uchar  local_x = get_local_id(0); // max size is 11
	uchar  local_y = get_local_id(1); // max size is 11
	ushort local_z = get_local_id(2); // max size is 4096
	uchar  block_x = get_group_id(0); // max size is 227
	uchar  block_y = get_group_id(1); // max size is 227
	ushort block_z = get_group_id(2); // max size is 4096
	uchar  local_size_x = get_local_size(0); // max size is 11
	uchar  local_size_y = get_local_size(1); // max size is 11
	ushort local_size_z = get_local_size(2); // max size is 4096
	uchar  group_size_x = get_num_groups(0); // max size is 227
	uchar  group_size_y = get_num_groups(1); // max size is 227
	ushort group_size_z = get_num_groups(2); // max size is 4096
	
	// Input Data, Weights and Bias
	lane_data     data_vec;
	channel_vec   data_ch_vec;
	channel_vec   weight_ch_vec;
	channel_scal  bias_ch_in;
	ushort        data_offset;
	
	// special case, the output feature maps depend on only half the input feature maps
	if(split==0)
		data_offset = 0;
	else if(block_z<(group_size_z>>1))
		data_offset = 0;	
	else
		data_offset = local_size_z;	

	
	// fetch weights and bias for the current group
	if(((block_y*stride<padding) && local_y<padding-block_y*stride)||((((group_size_y-1)-block_y)*stride<padding) && (local_size_y-1-local_y)<padding-((group_size_y-1)-block_y)*stride)||
		((block_x*stride<padding) && local_x<padding-block_x*stride)||((((group_size_x-1)-block_x)*stride<padding) && (local_size_x-1-local_x)<padding-((group_size_x-1)-block_x)*stride)){
		// padding with zeros
		#pragma unroll
		for(unsigned char vv=0; vv<VEC_SIZE; vv++){
			data_vec.data[vv] = CZERO;
		}
	}
	else
		data_vec = bottom[data_offset*data_dim2*data_dim1 + local_z*data_dim2*data_dim1 + block_y*stride*data_dim1 + (local_y-padding)*data_dim1 + block_x*stride + (local_x-padding)];

	weight_ch_vec = weights[block_z*weight_dim2*weight_dim1*local_size_z + local_z*weight_dim2*weight_dim1 + local_y*weight_dim1 + local_x];
	
	#pragma unroll
	for(unsigned char ll=0; ll<LANE_NUM; ll++){
		data_ch_vec.lane[ll] = data_vec;
	}
	write_channel_intel(data_ch, data_ch_vec);
	write_channel_intel(weight_ch, weight_ch_vec);
	#ifdef DEBUG_MEMRD
	if(global_y==0 && global_x==0){
	printf("work-item x=%d, y=%d, z=%d, offset=%d, write data in channel 0=%f\n", global_x, global_y, global_z, data_offset, (float)data_ch_vec.lane[0].data[0]);
	printf("work-item x=%d, y=%d, z=%d, offset=%d, write weight in channel 0=%f\n", global_x, global_y, global_z, data_offset, (float)weight_ch_vec.lane[0].data[0]);
	}
	#endif

	if(local_z==0 && local_y==0 && local_x==0){
		bias_ch_in = bias[block_z];
		write_channel_intel(bias_ch, bias_ch_in);
		//#ifdef DEBUG_MEMRD
		//printf("work-item x=%d, y=%d, z=%d, channel =0, write bias=%f\n", global_x, global_y, global_z, bias_ch_in.lane[0]);
		//#endif
	}

	//printf("Kernel 0 lanched !!!\n");
}


__kernel
__attribute__((task))
__attribute__((max_global_work_dim(0)))
void coreConv(
			// Params Ports
			uint  output_num,
			uint  conv_loop_cnt,
			uint  contol, //[0]-> relu  [1]->bypass pooling
			char  frac_w,
			char  frac_din,
			char  frac_dout
			)
{
	channel_vec mac_data;
 	channel_vec mac_weight;
	channel_scal bias_ch_out;
	channel_scal conv_ch_in;
	DPTYPE  bias[LANE_NUM];
	MACTYPE conv_out[LANE_NUM];
	MACTYPE lane_accum[LANE_NUM];
	MACTYPE accum_piped[LANE_NUM][PIPE_DEPTH];
	MACTYPE conv_sign_exten[LANE_NUM];
	MACTYPE conv_with_rnd_bit[LANE_NUM];
	MACTYPE conv_sum_bias[LANE_NUM];
	DPTYPE  conv_final[LANE_NUM];

	// each iteration generates one output
	for(unsigned int k=0; k<output_num; k++){
		
		bias_ch_out = read_channel_intel(bias_ch);

		#pragma unroll
		for(unsigned char ll=0; ll<LANE_NUM; ll++){

			conv_out[ll] = CZERO;
			bias[ll] = bias_ch_out.lane[ll]; // pass to reg, avoid compile error

			// initialize the deep pipelined registers which store PIPE_DEPTH copys of partial results
			#pragma unroll
			for(unsigned int p=0; p<PIPE_DEPTH; p++){
				accum_piped[ll][p] = MASK_ACCUM & CZERO;
			}
		}

		for(int j=0; j<conv_loop_cnt; j++){

			// load data and weights for each lane 
			mac_data = read_channel_intel(data_ch);
			mac_weight = read_channel_intel(weight_ch);

			// add results from all lanes
			// accumulate with the last copy
			#pragma unroll
			for(unsigned char ll=0; ll<LANE_NUM; ll++){
				
				lane_accum[ll] = (MASK_ACCUM & accum_piped[ll][PIPE_DEPTH-1]) + (MASK_MULT & mac(mac_data.lane[ll], mac_weight.lane[ll]));
			
				// Shift the pipelined registers backwards
				#pragma unroll
				for(unsigned int p=PIPE_DEPTH-1; p>0; p-- ){
					accum_piped[ll][p] = MASK_ACCUM & accum_piped[ll][p-1];
				}
				
				// update the first copy
				accum_piped[ll][0] = MASK_ACCUM & lane_accum[ll];

				#ifdef DEBUG_CONV
				if(ll==0 && k==0){
					printf("dot_cnt=%d data=%f weight=%f (loop=%d, lane= %d, vec=0)\n", k, (float)mac_data.lane[ll].data[0], (float)mac_weight.lane[ll].data[0], j, ll);
				}
				#endif
			}
		}// end of conv loop

		#pragma unroll
		for(unsigned char ll=0; ll<LANE_NUM; ll++){

			// accumulate all the partial results
			#pragma unroll
			for(unsigned i=0; i<PIPE_DEPTH; i++){
				conv_out[ll] += accum_piped[ll][i];
			}
			
			// round and truncate the results to the output precision
			// note: ((frac_w+frac_din)-frac_dout)) should be checked by host to be a positive number
			if(conv_out[ll]>=0)
				conv_sign_exten[ll] = 0x00;
			else
				conv_sign_exten[ll] = ~(0xFFFFFFFF>>(frac_w+frac_din-frac_dout-1)); // ">>" is logic shift, then perform sign extension manually
			
			conv_with_rnd_bit[ll] = (conv_sign_exten[ll] | (conv_out[ll]>>(frac_w+frac_din-frac_dout-1))) + 0x01;

			if(conv_with_rnd_bit[ll]>=256)
				conv_sum_bias[ll] = MASK9B & 0xFF; //=255
			else if(conv_with_rnd_bit[ll]<-256)
				conv_sum_bias[ll] = MASK9B & 0x100; //=-256
			else
				conv_sum_bias[ll] = (MASK9B & conv_with_rnd_bit[ll])+(bias[ll]>>(frac_w-frac_dout-1))+0x01;

			conv_final[ll] = MASK8B & (conv_sum_bias[ll]>>0x01);  // remove the last rounding bit
			
			// Relu operation
			if((contol&0x01)==0x01){
				if((conv_final[ll]&MASKSIGN)==MASKSIGN) // MSB is sign bit
					conv_ch_in.lane[ll] = 0;
				else
					conv_ch_in.lane[ll] = conv_final[ll];
			}
			else
				conv_ch_in.lane[ll] = conv_final[ll];
			
			#ifdef DEBUG_CONV
			if(ll==0 && k==0)
				printf("dot_cnt=%d sum=%f rnd=%f sum_bias=%f final=%f (bias=%f)\n\n", k, (float)conv_out[ll], (float)conv_with_rnd_bit[ll], (float)conv_sum_bias[ll], (float)conv_final[ll], (float)bias[ll]);
			#endif	

		}

		// write convoluation results
		if((contol&0x02)==0x02)
			//by-pass pooling
			write_channel_intel(bypass_ch, conv_ch_in);
		else // to pooling kernel
			write_channel_intel(conv_ch, conv_ch_in);
			//printf("Write channel item-%d is written in channel %d...\n", k, ll);

	}// end of output loop
 
}


__kernel
__attribute__((task))
void maxPool(
			// Params Ports
			uint  input_num,
			uchar line_size,  // line_size should be no larger than POOL_LBUF_DEPTH
			uchar pool_size,  // by now, only pooling size no larger than 3
			uchar pool_stride
			
			)
{
	channel_scal conv_ch_out;
	channel_scal pool_final;

	DPTYPE line_buf_0[LANE_NUM][POOL_LBUF_DEPTH];
	DPTYPE line_buf_1[LANE_NUM][POOL_LBUF_DEPTH];
	uchar  line_buf_ptr;
	uchar  col_pool_cnt;
	uchar  row_pool_cnt;
	uchar  row_cnt;
	DPTYPE row_pool_reg[LANE_NUM];
	DPTYPE col_pool_reg[LANE_NUM];
	DPTYPE pool_reg[LANE_NUM][POOL_MAX_SIZE];
	
	// Each iteration consumes one output from convolution kernel
	// and then Pooling is performed in column and row directions
	line_buf_ptr = 0;
	row_pool_cnt = 0;
	col_pool_cnt = 0;
	for(unsigned int k=0; k<input_num; k++){

		conv_ch_out = read_channel_intel(conv_ch);
	
		// Two line buffer to form the 3x3 pooling window
		// First read from line buffer for pooling and then write new line into the line buffer
		#pragma unroll
		for(unsigned char ll=0; ll<LANE_NUM; ll++){
			// Max pooling among rows 
			// with the new value read from each line buffer
			if(pool_size==3)
				row_pool_reg[ll] = pool_max(line_buf_1[ll][line_buf_ptr], line_buf_0[ll][line_buf_ptr]);
			else // pool_size==2
				row_pool_reg[ll] = line_buf_0[ll][line_buf_ptr];
			
			pool_reg[ll][0] = pool_max(row_pool_reg[ll], conv_ch_out.lane[ll]);
			
			// Max pooling among colums
			// with previous row-pooling results stored in shift-registers
			if(pool_size==3)
				col_pool_reg[ll] = pool_max(pool_reg[ll][1], pool_reg[ll][2]);
			else //pool_size==2
				col_pool_reg[ll] = pool_reg[ll][1];

			pool_final.lane[ll] = pool_max(col_pool_reg[ll], pool_reg[ll][0]);

			// Update line buffer	
			line_buf_1[ll][line_buf_ptr] = line_buf_0[ll][line_buf_ptr];
			line_buf_0[ll][line_buf_ptr] = conv_ch_out.lane[ll];

			// Pushing the new row-pooling result into shift-registers
			#pragma unroll
			for(unsigned char p=POOL_MAX_SIZE-1; p>0; p--){
				pool_reg[ll][p]=pool_reg[ll][p-1];
			}
		}
		
		#ifdef DEBUG_POOL
		printf("Maxpool input_num=%d, line_buf_ptr=%d, row_pool_cnt=%d, col_pool_cnt=%d\n", k, line_buf_ptr, row_pool_cnt, col_pool_cnt);
		printf("        row_cnt=%d\n", row_cnt);
		#endif
		
		// Generates pooling pipeline register wr/rd pointer
		if(row_pool_cnt==(pool_size-1)){

			// For each time row_pool_cnt==(pool_size-1), waits for col_pool_cnt==(pool_size-1)
			// then, a correct pooling operation is ready to be performed
			// Pooling window slide counter for columns
			if(col_pool_cnt==(pool_size-1)){
				// Correct max pooling is performed, result is write to channel
				write_channel_intel(pool_ch, pool_final);
				#ifdef DEBUG_POOL
				printf("        reg0=%f, reg1=%f, reg2=%f, max=%f\n", (float)pool_reg[0][0], (float)pool_reg[0][1], (float)pool_reg[0][2], (float)pool_final.lane[0]);
				#endif

				col_pool_cnt = (pool_size-pool_stride);
			}
			else
				col_pool_cnt = col_pool_cnt + 1;
		}
		else
			col_pool_cnt = 0;

		// Generates line buffer wr/rd pointer
		if(line_buf_ptr==(line_size-1)){
			line_buf_ptr = 0;

			// Row counters for recognize frames
			if(row_cnt == (line_size-1)) // assuming row_num = line_size, i.e. rectangular frame
				row_cnt = 0;
			else
				row_cnt = row_cnt + 1;

			// Pooling window slide counter for rows
			if(row_cnt == 0)
				row_pool_cnt = 0;
			else if(row_pool_cnt==(pool_size-1))
				row_pool_cnt = (pool_size-pool_stride);
			else
				row_pool_cnt = row_pool_cnt + 1;
		}
		else{
			line_buf_ptr = line_buf_ptr + 1;
		}

	}
}


// Store Data to Global Memory
__kernel
__attribute__((reqd_work_group_size(1,1,LANE_NUM)))
void memWrite(
				// Params Ports
				uchar  out_dim1,
				uchar  out_dim2,
				ushort out_dim3,
				ushort out_dim1xbatch, // out_dim1 x sqrt(batch_size)
				uint   out_dim1x2xbatch, // out_dim1 x out_dim2 x batch_size
				uchar  batch_indx_dim1,
				uchar  batch_indx_dim2,
				uchar  bypass,
				uchar  padd_offset,
				// Data Ports
                __global DPTYPE *restrict top
				)
{
	uchar  global_x = get_global_id(0); // max value 256
	uchar  global_y = get_global_id(1); // max value 256
	ushort global_z = get_global_id(2); // max value 4096
	uchar  local_x 	= get_local_id(0); // max value 256
	uchar  local_y 	= get_local_id(1); // max value 256
	uchar  local_z 	= get_local_id(2); // max value 256

	uchar  index_z_item; // max value 256
	ushort index_z_group;// max value 4096

	channel_scal   output;
	__local DPTYPE buffer[LANE_NUM];

	// use the first local work-item to read the vectorized output data from channel
	if(local_z==0){
		if((bypass&0x01)==0x01)
			output = read_channel_intel(bypass_ch);
		else
			output = read_channel_intel(pool_ch);

		// store the vectorized output into local buffer
		for(uchar ll=0; ll<LANE_NUM; ll++){
			buffer[ll]=output.lane[ll];
		}
	}

	barrier(CLK_LOCAL_MEM_FENCE);


	// fetch data from local buffer and write back to DDR
	// perform vectorization in dim3 (global_z) by combining multiple DPTYPE data into lane_data type
	index_z_group = (global_z-padd_offset)/VEC_SIZE;
	index_z_item  = (global_z-padd_offset)%VEC_SIZE;

	// output dim3 in current layer may be larger than next layer (the value is changed to a value of multiples of LANE_NUM to saturated the wide pipeline input) 
	// therefore, only write back the valid values without padding zeros
	if((global_z-padd_offset)<out_dim3 && (global_z>=padd_offset)){
		
		// 1. addressing expression with out batch processing is
		// top[index_z_group*dim1*dim2*VEC_SIZE + global_y*dim1*VEC_SIZE + global_x*VEC_SIZE + index_z_item]=buffer[local_z];
		// 2. addressing expression with batch processing (batch_size_in_dim = sqrt(batch_size)) is
		// top[(index_z_group*out_dim2*out_dim1*batch_size_in_dim*batch_size_in_dim*VEC_SIZE + (global_y+batch_indx_dim2*out_dim2)*batch_size_in_dim*out_dim1*VEC_SIZE + (global_x+batch_indx_dim1*out_dim1)*VEC_SIZE + index_z_item] = buffer[local_z];
		// 3. simplified addressing with reduced cost of multipliers
		top[index_z_group*out_dim1x2xbatch*VEC_SIZE + (global_y+batch_indx_dim2*out_dim2)*out_dim1xbatch*VEC_SIZE + (global_x+batch_indx_dim1*out_dim1)*VEC_SIZE + index_z_item] = buffer[local_z];

		#ifdef DEBUG_MEMWR
		if((global_z-padd_offset) == 0){
			//for(unsigned char ll=0; ll<LANE_NUM; ll++){
			printf("MemWr results= %f (x=%d, y=%d, z=%d, ll=%d)\n", (float)output.lane[0], global_x, global_y, global_z, 0);
			//}
			}
		#endif

	}
	
	barrier(CLK_LOCAL_MEM_FENCE);

}


__kernel
__attribute__((max_work_group_size(LRN_MAX_LOCAL_SIZE)))
void lrn(
			// Params Ports
			uchar data_dim1,
			uchar data_dim2,
			char  frac_dout,
			// Data Ports
			__global lane_data *restrict bottom,
			__global lane_data *restrict top
		)
{
	uchar  global_x = get_global_id(0); // max value 256
	uchar  global_y = get_global_id(1); // max value 256
	ushort global_z = get_global_id(2); // max value 4096

	#ifdef DEBUG_LRN
	int local_x = get_local_id(0);
	int local_y = get_local_id(1);
	int local_z = get_local_id(2);
	int block_x = get_group_id(0);
	int block_y = get_group_id(1);
	int block_z = get_group_id(2);
	#endif
	
	__local DPTYPE z_buffer[VEC_SIZE*LRN_MAX_LOCAL_SIZE+LRN_WIN_SIZE]; // allocate two more points for padding
	__local DPTYPE lrn_buffer[VEC_SIZE*LRN_MAX_LOCAL_SIZE];
	channel_scal data_in;
	channel_scal data_pad_left;
	channel_scal data_pad_right;
	channel_scal data_out;
	lane_data    data_in_partial;
	lane_data    data_left_partial;
	lane_data    data_right_partial;
	lane_data    data_out_partial;
	int          *convert_ptr;
	int          expo;
	uint         manti;
	uint         addr_1, addr_2, addr;
	float        lrn_reg1, lrn_reg2, lrn_tmp, lrn_out;
	short        lrn_cnvt, lrn_cnvt2;
	
	// Load the all data in one line along dim3 into local line buffer
	#pragma unroll
	for(unsigned char ll=0; ll<VEC_SIZE; ll++){
		z_buffer[global_z*VEC_SIZE+ll+LRN_WIN_SIZE/2] = bottom[global_z*data_dim2*data_dim1 + global_y*data_dim1+ global_x].data[ll];
	}
	
	//Padding left
	if(global_z==0){
		#pragma unroll
		for(unsigned char ll=0; ll<LRN_WIN_SIZE/2; ll++){
			z_buffer[ll] = CZERO;
		}
	}

	// Padding right
	if(global_z==(get_global_size(2)-1)){
		#pragma unroll
		for(unsigned char ll=0; ll<LRN_WIN_SIZE/2; ll++){
			z_buffer[VEC_SIZE*get_local_size(2)+ll+LRN_WIN_SIZE/2] = CZERO;
		}
	}

	#ifdef DEBUG_LRN
	if(global_z==0&&global_x==0&&global_y==0)
	printf("Kernel LRN: work-item x=%d, y=%d, z=%d(z_local=%d)\n", global_x, global_y, global_z, local_z);
	#endif
	barrier(CLK_LOCAL_MEM_FENCE); // fill all values of the line bufer before reading it

	// Piecewise interpolation pipeline for lrn operation
	for(unsigned char ll=0; ll<VEC_SIZE; ll++){
		lrn_reg2 = CZERO;
		#pragma unroll
		for(char k=-LRN_WIN_SIZE/2; k<=LRN_WIN_SIZE/2; k++){
			lrn_cnvt = z_buffer[global_z*VEC_SIZE+ll+k+LRN_WIN_SIZE/2]<<(-frac_dout);
			lrn_reg1 = convert_float(lrn_cnvt);
			lrn_reg2 += lrn_reg1 * lrn_reg1;
			#ifdef DEBUG_LRN
			if(global_z==0&&global_x==0&&global_y==0)
			printf("x=%f(k=%d), ", lrn_reg1, k);
			#endif
		}
		convert_ptr = (int*) (&lrn_reg2);
		expo = (EXP_MASK & (*convert_ptr >> MAN_BITS)) - 127;
		manti = ((*convert_ptr) & MAN_MASK);
		
		addr_1 = ((expo-EXP_STEP_MIN)>>EXP_STEP_LOG)<<MAN_INDEX_BITS;
		addr_2 = (manti>>(MAN_BITS-MAN_INDEX_BITS) & MAN_INDEX_MASK)+1;
		if(expo<EXP_STEP_MIN)
			addr = 0;
		else
			addr = addr_1+addr_2;

		lrn_tmp = ((lrn_reg2-x_sample[addr])*h_inv[addr])*coef1[addr] + coef0[addr];	
		
		lrn_cnvt2 = z_buffer[global_z*VEC_SIZE+ll+LRN_WIN_SIZE/2]<<(-frac_dout);
		lrn_out = lrn_tmp*convert_float(lrn_cnvt2);

		// Convert float to DPTYPE fixed-point
		// Note: current version only support frac_din=0 for next layer
		lrn_buffer[global_z*VEC_SIZE+ll] = convert_char_rte(lrn_out);

		#ifdef DEBUG_LRN
		if(global_z==0&&global_x==0&&global_y==0)
		printf("\nKernel LRN (ll=%d): pwlf_x=%f, expo=%d, addr=%d, pwlf_y=%f, lrn=%f\n", ll, lrn_reg2, expo, addr, lrn_tmp, lrn_out);
		#endif
		barrier(CLK_LOCAL_MEM_FENCE);
	}

	// Store the results back to global mem
	#pragma unroll
	for(unsigned char vv=0; vv<VEC_SIZE; vv++){
		data_out_partial.data[vv]=lrn_buffer[global_z*VEC_SIZE+vv];
	}
	top[global_z*data_dim2*data_dim1 + global_y*data_dim1 + global_x] = data_out_partial;
	
	#ifdef DEBUG_LRN_OUT
	if(global_z==0&&global_x==0&&global_y==0)
	printf("\nKernel LRN OUT: x=%d, y=%d, z=%d, result=%f\n", global_x, global_y, global_z, (float)data_out_partial.data[0]);
	#endif

}

