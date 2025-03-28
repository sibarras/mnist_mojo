from gpu.host import DeviceContext, DeviceBuffer, HostBuffer
from layout import Layout, LayoutTensor
from layout.math import sum
from data_traits import HasData

from builtin.builtin_slice import slice
from os import abort
from algorithm import sync_parallelize
from memory import UnsafePointer, memcpy
import random
from image import print_grayscale
from math import sqrt

alias MAX_BLOCKS_1D = 1024
"""The dim multiplication should be less or equal than 1024."""

alias MAX_BLOCKS_2D = sqrt(MAX_BLOCKS_1D)
"""The max for 2D blocks."""

alias MAX_BLOCKS_3D = MAX_BLOCKS_1D ** (1 / 3)
"""The max for 3D blocks."""


fn get_gpu() raises -> DeviceContext:
    random.seed(0)
    return DeviceContext()


fn enqueue_create_buf[
    dtype: DType
](ctx: DeviceContext, size: Int) raises -> DeviceBuffer[dtype]:
    buf = ctx.enqueue_create_buffer[dtype](size)
    return buf.enqueue_fill(0)


fn enqueue_create_host_buf[
    dtype: DType
](ctx: DeviceContext, size: Int) raises -> HostBuffer[dtype]:
    buf = ctx.enqueue_create_host_buffer[dtype](size)
    return buf.enqueue_fill(0)


fn enqueue_host_to_gpu[
    dtype: DType
](ctx: DeviceContext, host_buff: HostBuffer[dtype]) raises -> DeviceBuffer[
    dtype
]:
    gpu_buff = ctx.enqueue_create_buffer[dtype](len(host_buff))
    gpu_buff.enqueue_copy_from(host_buff)
    return gpu_buff


fn enqueue_gpu_to_host[
    dtype: DType
](ctx: DeviceContext, gpu_buff: DeviceBuffer[dtype]) raises -> HostBuffer[
    dtype
]:
    host_buff = ctx.enqueue_create_host_buffer[dtype](len(gpu_buff))
    gpu_buff.enqueue_copy_to(host_buff)
    return host_buff


fn enqueue_buf_to_tensor[
    dtype: DType, //, layout: Layout
](ctx: DeviceContext, b: DeviceBuffer[dtype]) -> LayoutTensor[
    dtype, layout, b.origin
]:
    return LayoutTensor[dtype, layout](b)


fn enqueue_randomize(ctx: DeviceContext, gpu_buffer: DeviceBuffer) raises:
    size = len(gpu_buffer)
    host_buffer = ctx.enqueue_create_host_buffer[gpu_buffer.type](size)
    random.rand(host_buffer.unsafe_ptr(), size, min=-0.1, max=0.1)
    gpu_buffer.enqueue_copy_from(host_buffer)


fn enqueue_create_matrix[
    size: Int,
    *,
    dtype: DType,
    randomize: Bool = False,
    layout: Layout = Layout.row_major(size),
](ctx: DeviceContext) raises -> (
    DeviceBuffer[dtype],
    LayoutTensor[dtype, layout, MutableAnyOrigin],
):
    var b = enqueue_create_buf[dtype](ctx, size)

    @parameter
    if randomize:
        enqueue_randomize(ctx, b)

    return b, enqueue_buf_to_tensor[layout](ctx, b)


fn enqueue_create_matrix[
    rows: Int,
    cols: Int,
    *,
    dtype: DType,
    randomize: Bool = False,
    layout: Layout = Layout.row_major(rows, cols),
](ctx: DeviceContext) raises -> (
    DeviceBuffer[dtype],
    LayoutTensor[dtype, layout, MutableAnyOrigin],
):
    var b = enqueue_create_buf[dtype](ctx, rows * cols)

    @parameter
    if randomize:
        enqueue_randomize(ctx, b)

    return b, enqueue_buf_to_tensor[layout](ctx, b)


fn enqueue_images_to_gpu_matrix[
    img_type: HasData,
    layout: Layout,
](
    ctx: DeviceContext,
    buff: DeviceBuffer[img_type.dtype],
    tensor: LayoutTensor[img_type.dtype, layout, MutableAnyOrigin],
    images: List[img_type],
) raises:
    local_buff = enqueue_create_host_buf[img_type.dtype](
        ctx, len(buff)  # Doesn't matter right now
    )
    local_buff = local_buff.enqueue_fill(0)
    local_tensor = __type_of(tensor)(local_buff)

    alias pixels: Int = tensor.shape[0]()
    alias images_: Int = tensor.shape[1]()

    if len(images) != images_:
        abort("Img len didn't matck")
    if img_type.size != pixels:
        abort("Img pixels didn't matck")

    for pixel in range(pixels):
        for image in range(images_):
            control = Int(images[image].get_data()[pixel])
            local_tensor[pixel, image] = control

    buff.enqueue_copy_from(local_buff)
