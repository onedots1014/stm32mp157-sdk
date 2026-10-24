import tensorflow as tf

interp = tf.lite.Interpreter("micro_speech_quantized.tflite")
interp.allocate_tensors()

inp = interp.get_input_details()[0]
out = interp.get_output_details()[0]

print("Input  scale:", inp['quantization'][0],  "zero_point:", inp['quantization'][1])
print("Output scale:", out['quantization'][0], "zero_point:", out['quantization'][1])
