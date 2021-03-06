/*****************************************************************************
 Jedda Boyle

 CONTAINS:
 OpenCL code defining the GPU kernels used for RFI mitigation.

 NOTES:

  *****************************************************************************/


kernel void reduce (global float *d_out, 
		            global float *d_in, 
					int n, 
					local volatile float *ldata) {
	int tid = get_local_id(0);
	int gid = 256 * get_group_id(0) + tid; // Each work group reduces 256 values.

	// Read data into shared memory and do first reduce operation.
	ldata[tid] = (gid < n) ? d_in[gid] : 0;
	ldata[tid] += gid + 128 < n ? d_in[gid + 128] : 0;
	barrier(CLK_LOCAL_MEM_FENCE);

	// Do reduce across work group.
	if (tid < 64) {
		ldata[tid] += ldata[tid + 64];
	}
	barrier(CLK_LOCAL_MEM_FENCE);

	// Do reduce across warp.
	if (tid < 32) {
		ldata[tid] += ldata[tid + 32]; 
		ldata[tid] += ldata[tid + 16];
		ldata[tid] += ldata[tid +  8];
		ldata[tid] += ldata[tid +  4];
		ldata[tid] += ldata[tid +  2];
		ldata[tid] += ldata[tid +  1];
	}

	// Write result.
	if (tid == 0) d_out[get_group_id(0)] = ldata[0];
}


kernel
void transpose (global uchar *d_out, 
		        const global uchar *d_in, 
				int m, int n, 
				local uchar *ldata) 
{
	int gid_x = get_global_id(0);
	int gid_y = get_global_id(1);
	if (gid_x < m && gid_y < n) {
		d_out[gid_y * m + gid_x] = d_in[gid_x * n + gid_y];
	}
}


kernel
void scalar_division (global float* d_out, 
		              global int *d_in, 
					  int value, 
					  int n) 
{
	int gid = get_global_id(0);

	if (gid >= n) return; 

	d_out[gid] = ((float) d_in[gid]) / value;

}

#define MEAN_EDGE_UNROLLED_LOOP(w) \
	if (i + w >= n) return; \
	window_sum += ldata[tid + w - 1]; \
	value = min(fabs((window_sum / w) - ldata[tid - 1]), fabs((window_sum / w) - ldata[tid + w])); \
	if (value > T) { \
		for (int j = 0; j < w; j++) { \
			m_out[gid_x * N + i + j] = 1; \
		} \
	} \
	if (max_window_size == w) continue;

kernel
void mean_edge_threshold(global uchar *m_out, 
					global uchar *d_in, 
					global uchar *mads, 
					float threshold, 
					int max_window_size, 
					int m, int n, int N,
					local float *ldata)
{
	int gid_x = get_global_id(0);
	int gid_y = get_global_id(1);
	int ny = get_local_size(1);
	int tid = get_local_id(1) + 1;

	if (gid_x >= m) return;


	float value;
	float T = mads[gid_x] * 1.4826 * threshold;


	// Do first step.
	ldata[tid] = d_in[gid_x * N + tid - 1];	
	if (ny - tid < max_window_size) {
		ldata[tid + max_window_size] = d_in[gid_x * N + (tid - 1) + max_window_size];
	}
	barrier(CLK_LOCAL_MEM_FENCE);

	float window_sum = 0.0;
	if (tid != 1) {
		for (int w = 1; w <= max_window_size; w++) {
			window_sum += ldata[tid + w - 1];
			value = min(fabs((window_sum / w) - ldata[tid - 1]), fabs((window_sum / w) - ldata[tid + w]));
			if (value > T) {
				for (int j = 0; j < w; j++) {
					m_out[gid_x * N + tid - 1 + j] = 1;	
				}
			}
		}
	}

	// Do the steps almost to the end.
	for (int i = gid_y + ny; i < n; i += ny) {
		ldata[tid] = d_in[gid_x * N + i];	
		if (tid == 1)  ldata[0]       = d_in[gid_x * N + i - 1];
		if (ny - tid < max_window_size) {
			ldata[tid + max_window_size] = d_in[gid_x * N + i + max_window_size];
		}
		barrier(CLK_LOCAL_MEM_FENCE);


		window_sum = 0.0;
		MEAN_EDGE_UNROLLED_LOOP(1);
		MEAN_EDGE_UNROLLED_LOOP(2);
		MEAN_EDGE_UNROLLED_LOOP(3);
		MEAN_EDGE_UNROLLED_LOOP(4);
		MEAN_EDGE_UNROLLED_LOOP(5);
		MEAN_EDGE_UNROLLED_LOOP(6);
		MEAN_EDGE_UNROLLED_LOOP(7);
		MEAN_EDGE_UNROLLED_LOOP(8);
		MEAN_EDGE_UNROLLED_LOOP(9);
		MEAN_EDGE_UNROLLED_LOOP(10);
		for (int w = 11; w <= max_window_size; w++) {
			if (i + w >= n) return;
			window_sum += ldata[tid + w - 1];
			value = min(fabs((window_sum / w) - ldata[tid - 1]), fabs((window_sum / w) - ldata[tid + w]));
			if (value > T) {
				for (int j = 0; j < w; j++) {
					m_out[gid_x * N + i + j] = 1;
				}
			}
		}
	}

}


#define POINT_EDGE_UNROLLED_LOOP(w) \
	if (i + w >= n) return; \
	for (int k = 0; k < w; k++) { \
		value = min(fabs(ldata[tid + k] - ldata[tid - 1]), fabs(ldata[tid + k] - ldata[tid + w])); \
		if (value > T) { \
			m_out[gid_x * N + i + k] = 1; \
		} \
	} \
	if (max_window_size == w) continue;



kernel
void point_edge_threshold(global uchar *m_out, 
					global uchar *d_in, 
					global uchar *mads, 
					float threshold, 
					int max_window_size, 
					int m, int n, int N,
					local float *ldata)
{
	int gid_x = get_global_id(0);
	int gid_y = get_global_id(1);
	int ny = get_local_size(1);
	int tid = get_local_id(1) + 1;

	if (gid_x >= m) return;


	float value;
	float T = mads[gid_x] * 1.4826 * threshold;


	// Do first step.
	ldata[tid] = d_in[gid_x * N + tid - 1];	
	if (ny - tid < max_window_size) {
		ldata[tid + max_window_size] = d_in[gid_x * N + (tid - 1) + max_window_size];
	}
	barrier(CLK_LOCAL_MEM_FENCE);

	if (tid != 1) {
		for (int w = 1; w <= max_window_size; w++) {
			for (int k = 0; k < w; k++) {
				value = min(fabs(ldata[tid + k] - ldata[tid - 1]), fabs(ldata[tid + k] - ldata[tid + w]));
				if (value > T) {
					m_out[gid_x * N + tid - 1 + k] = 1;
				}
			}
		}
	}

	// Do the steps almost to the end.
	for (int i = gid_y + ny; i < n; i += ny) {
		ldata[tid] = d_in[gid_x * N + i];	
		if (tid == 1)  ldata[0]       = d_in[gid_x * N + i - 1];
		if (ny - tid < max_window_size) {
			ldata[tid + max_window_size] = d_in[gid_x * N + i + max_window_size];
		}
		barrier(CLK_LOCAL_MEM_FENCE);

		POINT_EDGE_UNROLLED_LOOP(1);
		POINT_EDGE_UNROLLED_LOOP(2);
		POINT_EDGE_UNROLLED_LOOP(3);
		POINT_EDGE_UNROLLED_LOOP(4);
		POINT_EDGE_UNROLLED_LOOP(5);
		POINT_EDGE_UNROLLED_LOOP(6);
		POINT_EDGE_UNROLLED_LOOP(7);
		POINT_EDGE_UNROLLED_LOOP(8);
		POINT_EDGE_UNROLLED_LOOP(9);
		POINT_EDGE_UNROLLED_LOOP(10);

		for (int w = 11; w <= max_window_size; w++) {
			if (i + w >= n) return;
			for (int k = 0; k < w; k++) {
				value = min(fabs(ldata[tid + k] - ldata[tid - 1]), fabs(ldata[tid + k] - ldata[tid + w]));
				if (value > T) {
					m_out[gid_x * N + i + k] = 1;
				}
			}

		}
	}

}


kernel
void sum_threshold(global uchar *m_out, 
			       global uchar *d_in, 
				   global uchar *m_in, 
				   global uchar *medians, 
				   int window_size, 
				   int iter,
				   float alpha,
				   int m, int n, int N,
				   local float *ldata, 
				   local float *lmask, 
				   local float *lthresholds)
{

	int gid_x = get_global_id(0);
	int gid_y = get_global_id(1);
	int tid_x = get_local_id(0);
	int tid_y = get_local_id(1);
	int tile_width = get_local_size(1) + window_size;
	int tid = tid_x * tile_width + tid_y;
	int gid = gid_x * N + gid_y;

	// Read data into shared local memory.	
	if (gid_x < m && gid_y < n) {
		ldata[tid] = d_in[gid];
		lmask[tid] = m_in[gid];
		/*m_out[gid] = m_in[gid];*/
	}

	// Compute and save threshold from median.
	if (tid_y == 0) {
		/*lthresholds[tid_x] = alpha + std::pow(1.5, iter) +  medians[gid_x];*/
		/*lthresholds[tid_x] = pow(1.5, iter) / window_size;*/
		lthresholds[tid_x] = alpha * ((float) pow(1.5, iter) / window_size) + medians[gid_x];
	}

	// Read data into shared local memory that is needed by the right most threads 
	// in the work group but are not directly computed as part of the work group.
	int d = get_local_size(0) - tid_y - 1;
	if (d <= window_size && gid_y + window_size < n) {
		ldata[tid + window_size] = d_in[gid + window_size];
		lmask[tid + window_size] = m_in[gid + window_size];
	}

	// Wait for all threads to have initialised shared local memory.
	barrier(CLK_LOCAL_MEM_FENCE);

	// Return if current window reaches beyond end of data.
	if (gid_x >= m || gid_y >= n - window_size + 1) {
		return;
	}

	// Do computation on shared local memory.
	float window_sum = 0;
	int count = 0;
	for (int i = 0; i < window_size; i++) {
		if (lmask[tid + i] != 1) {
			count += 1;
			window_sum += ldata[tid + i];
		}
	}

	// Check if window should be masked.
	if (window_sum > lthresholds[tid_x] * count) {
		// Mask window.
		for (int i = 0; i < window_size; i++) {
			m_out[gid + i] = 1;
		}
	}


}


kernel 
void compute_mads(global uchar *mads, 
		          global uchar *medians, 
				  global uchar *data, 
				  int m, int n, int N,
				  local volatile int *ldata) 
{
	int gid_x = get_global_id(0);
	int lid = get_local_id(0) * 256;
	int ny = get_local_size(1);
	int tid_y = get_local_id(1);

	if (gid_x >= m) { 
		return;
	}
	for (int i = tid_y; i < 256; i += ny) {
		ldata[lid + i] = 0;
	}

	barrier(CLK_LOCAL_MEM_FENCE);

	int val;
	for (int i = tid_y; i < n; i += ny) {
		val = data[gid_x * N + i];
		atomic_inc(ldata + lid + val);
	}

	barrier(CLK_LOCAL_MEM_FENCE);

	int count;
	if (tid_y == 0) {
		count = 0;
		for (int i = 0; i < 256; i++) {
			count += ldata[lid + i];
			ldata[lid + i] = 0;
			if (count > n / 2) {
				medians[gid_x] = i;
				break;
			
			}
		}
	}
	
	barrier(CLK_LOCAL_MEM_FENCE);

	for (int i = tid_y; i < n; i += ny) {
		val = abs(data[gid_x * N + i] - medians[gid_x]);
		atomic_inc(ldata + lid + val);
	}

	barrier(CLK_LOCAL_MEM_FENCE);

	if (tid_y != 0) return;

	count = 0;
	for (int i = 0; i < 256; i++) {
		count += ldata[lid + i];
		if (count > n / 2) {
			mads[gid_x] = i;
			break;
		}
	}

		
}


kernel 
void compute_medians (global uchar *medians, 
		              global uchar *d_in, 
					  int m, int n, int N,
					  local volatile int *ldata) 
{
	int gid_x = get_global_id(0);
	int lid = get_local_id(0) * 256;
	int ny = get_local_size(1);
	int tid_y = get_local_id(1);

	if (gid_x >= m) return;

	for (int i = tid_y; i < 256; i += ny) {
		ldata[lid + i] = 0;
	}

	barrier(CLK_LOCAL_MEM_FENCE);

	int val;
	for (int i = tid_y; i < n; i += ny) {
		val = d_in[gid_x * N + i];
		atomic_inc(ldata + lid + val);
	}

	barrier(CLK_LOCAL_MEM_FENCE);

	if (tid_y != 0) return;

	int count = 0;
	for (int i = 0; i < 256; i++) {
		count += ldata[lid + i];
		if (count > n / 2) {
			medians[gid_x] = i;
			break;
		}
	}

}


kernel 
void compute_col_sums(volatile global int *d_out, 
		              global uchar *d_in, 
				      int lx, int ly,
				      int m, int n, int N,
				      volatile local int *ldata) 
{
	int tid_x = get_local_id(0);
	int tid_y = get_local_id(1);
	int gid_x = get_group_id(0) * lx + tid_x;
	int gid_y = get_group_id(1) * ly + tid_y;
	if (gid_x >= m || gid_y >= n) return;

	int end_x = min((int) get_group_id(0) * lx + lx, m);
	int end_y = min((int) get_group_id(1) * ly + ly, n);

	if (tid_x == 0) {
		for (int lj = tid_y; lj < ly; lj+= get_local_size(1)) {
			ldata[lj] = 0;
		}
	}
	
	barrier(CLK_LOCAL_MEM_FENCE);
	for (int i = gid_x; i < end_x; i += get_local_size(0)) {
		for (int j = gid_y, lj = tid_y; j < end_y; j += get_local_size(1), lj+= get_local_size(1)) {
			atomic_add(ldata + lj, (int) d_in[i * N + j]);
		}
	}
	barrier(CLK_LOCAL_MEM_FENCE);

	if (tid_x != 0) return;
	

	for (int j = gid_y, lj = tid_y; j < end_y; j += get_local_size(1), lj+= get_local_size(1)) {
		atomic_add(d_out + j, ldata[lj]);
	}

}



kernel 
void compute_means_old(global float *d_out, 
				   global uchar *d_in, 
				   int m, int n, int N,
				   local int *ldata) 
{
	int gid_x = get_global_id(0);
	int tid = get_local_id(1);
	int lid = get_local_id(0) * get_local_size(1) + tid; // index into local memory/
	if (gid_x >= m) return;

	ldata[lid] = 0;
	for (int i = tid; i < n; i += get_local_size(1)) {
		ldata[lid] += d_in[gid_x * N + i];
	}

	barrier(CLK_LOCAL_MEM_FENCE);
	/*if (tid < 128) {*/
		/*ldata[lid] += ldata[lid + 128];*/
	/*}*/
	barrier(CLK_LOCAL_MEM_FENCE);


	if (tid < 64) {
		ldata[lid] += ldata[lid + 64];
	}
	barrier(CLK_LOCAL_MEM_FENCE);

	if (tid < 32) {
		ldata[lid] += ldata[lid + 32]; 
		barrier(CLK_LOCAL_MEM_FENCE);
		ldata[lid] += ldata[lid + 16];
		barrier(CLK_LOCAL_MEM_FENCE);
		ldata[lid] += ldata[lid +  8];
		barrier(CLK_LOCAL_MEM_FENCE);
		ldata[lid] += ldata[lid +  4];
		barrier(CLK_LOCAL_MEM_FENCE);
		ldata[lid] += ldata[lid +  2];
		barrier(CLK_LOCAL_MEM_FENCE);
		ldata[lid] += ldata[lid +  1];
	}

	if (tid == 0) d_out[gid_x] = (float) ldata[lid] / n;


}


kernel
void compute_deviation(global float *d_out, 
		               global float *d_in, 
					   float mean, 
					   int n) 
{
	uint gid = get_global_id(0);

	if (gid >= n) return;

	d_out[gid] = pow(mean - d_in[gid], 2) / (n - 1);

}


kernel
void detect_outliers(global float *d_out, 
		             global float *d_in, 
		             float mean, 
					 float std, 
					 float threshold, 
					 int n) 
{ 
	uint gid = get_global_id(0);

	if (gid >= n) return;

	d_out[gid] = (fabs(d_in[gid] - mean) > std * threshold);	

}


kernel 
void mask_row_sum_threshold (global uchar *m_out, 
		           			 global uchar *m_in, 
				   			 int m, int n, int N,
				   			 local int *ldata) 
{
	int gid_x = get_global_id(0);
	int tid = get_local_id(1);
	int lid = get_local_id(0) * get_local_size(1) + tid; // index into local memory/
	if (gid_x >= m) return;

	ldata[lid] = 0;
	for (int i = tid; i < n; i += get_local_size(1)) {
		ldata[lid] += m_in[gid_x * N + i];
	}

	barrier(CLK_LOCAL_MEM_FENCE);

	if (tid < 64) {
		ldata[lid] += ldata[lid + 64];
	}
	barrier(CLK_LOCAL_MEM_FENCE);

	if (tid < 32) {
		ldata[lid] += ldata[lid + 32]; 
		barrier(CLK_LOCAL_MEM_FENCE);
		ldata[lid] += ldata[lid + 16];
		barrier(CLK_LOCAL_MEM_FENCE);
		ldata[lid] += ldata[lid +  8];
		barrier(CLK_LOCAL_MEM_FENCE);
		ldata[lid] += ldata[lid +  4];
		barrier(CLK_LOCAL_MEM_FENCE);
		ldata[lid] += ldata[lid +  2];
		barrier(CLK_LOCAL_MEM_FENCE);
		ldata[lid] += ldata[lid +  1];
	}

	barrier(CLK_LOCAL_MEM_FENCE);
	if (tid == 0 && ldata[lid] > 500) {
		for (int i = 0; i < n; i ++ ) {
			m_out[gid_x * N + i] = 1;
		}
	}


}


kernel 
void mask_rows(global uchar *m_out, 
		       global float *m_in, 
			   int m, int n, int N) 
{
	int gid_m = get_global_id(0);
	if (gid_m < m && m_in[gid_m] == 1) {
		int group_size_n = get_local_size(1);
		for (int i = get_local_id(1); i < n; i += group_size_n) {
			m_out[gid_m * N + i] = 1;
		}
	}
}


kernel
void replace_rfi_medians (global uchar *d_out, 
		                  global uchar *d_in, 
				          global uchar *m_in, 
				          global uchar *replace_values, 
				          int m, int n, int N) 
{
	int gid_x = get_global_id(0);
	int gid_y = get_global_id(1);

	if (gid_x >= m || gid_y >= n) return;

	int gid = gid_x * N + gid_y; 
	d_out[gid] = (m_in[gid] == 1 ? replace_values[gid_x] : d_in[gid]);

}


kernel
void replace_rfi_constant(global uchar *d_out, 
		                  global uchar *d_in, 
				          global uchar *m_in, 
				          int m, int n, int N) 
{
	int gid_x = get_global_id(0);
	int gid_y = get_global_id(1);

	if (gid_x >= m || gid_y >= n) return;

	int gid = gid_x * N + gid_y; 
	d_out[gid] = (m_in[gid] == 1 ? 0 : d_in[gid]);

}



/*kernel*/
/*void transpose(global uchar *d_out, const global uchar *d_in, int m, int n, local uchar *tile) {*/
	/*int tile_dim = get_local_size(1)*/
	/*uint group_x = get_group_id(0);*/
	/*uint group_y = get_group_id(1);*/
	/*uint x = group_x * tile_dim + get_local_id(0);*/
	/*uint y = get_global_id(1);*/
	/*for (uint i = 0; i < tile_dim; i += get_local_size(0)) {*/
		/*tile[get_local_id(1) * tile_dim + (get_local_id(0)+i)] = d_in[(x + i) * n + y];*/
	/*}*/
	/*barrier(CLK_LOCAL_MEM_FENCE | CLK_GLOBAL_MEM_FENCE);*/
	
	/*group_x = get_group_id(1);*/
	/*group_y = get_group_id(0);*/
	/*x = group_x * tile_dim + get_local_id(0);*/
	/*y = group_y * tile_dim + get_local_id(1);*/
		/*for (uint i = 0; i < tile_dim; i += get_local_size(0)) {*/
		/*if (x + i >= n || y >=m ) {*/
			/*return;*/
		/*}*/

		/*d_out[(x + i) * m + y] = tile[(get_local_id(0) + i) * tile_dim  + get_local_id(1)];*/
	/*}*/


/*}*/

/*kernel*/
/*void transpose(global uchar *d_out, global uchar *d_in, int m, int n, local uchar *ldata) {*/
	/*int gid_x = get_global_id(0);*/
	/*int gid_y = get_global_id(1);*/
	/*int tid_x = get_local_id(0);*/
	/*int tid_y = get_local_id(1);*/
	/*[>int n_threads_x = get_local_size(1);<]*/
	/*int n_threads_x = 16;*/

	/*if (gid_x < n && gid_y < m) {*/
		/*ldata[tid_y * (n_threads_x + 1) + tid_x] = d_in[gid_y * n + gid_x];*/
	/*}*/

	/*barrier(CLK_LOCAL_MEM_FENCE);*/

	/*gid_x = get_group_id(1) * n_threads_x + get_local_id(0);*/
	/*gid_y = get_group_id(0) * n_threads_x + get_local_id(1);*/
	/*if (gid_x < m && gid_y < n) {*/
		/*d_out[gid_y * n + gid_x] = ldata[tid_x * (n_threads_x + 1) + tid_y];*/
	/*}*/

/*}*/











	




