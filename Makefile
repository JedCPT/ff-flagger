CXX = g++
SOURCE_FILES = filterbank.cpp device.cpp opencl_error_handling.cpp 

CFLAGS = -Wall -std=c++11 -DTIME
LIBS = -lrt -lOpenCL 
INCLUDES = -Iinclude -Iinclude/catch2

SRC_DIR := src
BUILD_DIR := build
TEST_DIR := test
OBJS := $(SOURCE_FILES:.cpp=.o)

SRCS := $(addprefix $(SRC_DIR)/, $(SOURCE_FILES))
OBJS := $(addprefix $(BUILD_DIR)/, $(OBJS))

DAS := prun -np 1 -native '-C TitanX --gres=gpu:1' 
#DAS = 

make: $(OBJS) $(SRCS)
	$(CXX) $(CFLAGS) $(LIBS) $(INCLUDES) $(OBJS) $(SRC_DIR)/main.cpp -o fflagger
	$(DAS) ./fflagger -i ~/real.fil -o ~/del.fil -m 2  --mad_threshold 3.5 -n 1
	$(DAS) ./fflagger -i ~/real.fil -o ~/del.fil -m 2  --mad_threshold 3.5 -n 2
	$(DAS) ./fflagger -i ~/real.fil -o ~/del.fil -m 4  --mad_threshold 3.5 -n 1
	$(DAS) ./fflagger -i ~/real.fil -o ~/del.fil -m 4  --mad_threshold 3.5 -n 2

test: $(OBJS) $(SRCS)
	$(CXX) $(CFLAGS) $(LIBS) $(INCLUDES) $(OBJS) $(TEST_DIR)/tests.cpp -o $(BUILD_DIR)/tests
	$(DAS) $(BUILD_DIR)/tests [SumThreshold]

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.cpp
	$(CXX) $(CFLAGS) $(LIBS) $(INCLUDES) -c $<  -o $@


clean:
	rm build/* fflagger

	


