from gpu.host import DeviceContext, DeviceBuffer, HostBuffer
from layout import Layout as LY, LayoutTensor, IntTuple
from layout.math import sum
from data_traits import HasData, HasLabel

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


fn Layout(x: Int, y: Int, z: Int) -> LY:
    return LY(IntTuple(x, y, z))


fn Layout(x: Int, y: Int) -> LY:
    return LY(IntTuple(x, y))


fn Layout(x: Int) -> LY:
    return LY(IntTuple(x))


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
    o: MutableOrigin, dtype: DType, //, layout: LY
](ctx: DeviceContext, ref [o]b: DeviceBuffer[dtype]) -> LayoutTensor[
    dtype, layout, MutableAnyOrigin
]:
    ly = LayoutTensor[dtype, layout, MutableAnyOrigin](b)
    return ly


fn enqueue_buf_to_tensor(
    ctx: DeviceContext,
    like: LayoutTensor,
    mut b: DeviceBuffer[like.dtype],
) -> LayoutTensor[like.dtype, like.layout, MutableAnyOrigin]:
    return LayoutTensor[like.dtype, like.layout, MutableAnyOrigin](b)


fn enqueue_randomize(ctx: DeviceContext, gpu_buffer: DeviceBuffer) raises:
    size = len(gpu_buffer)
    host_buffer = ctx.enqueue_create_host_buffer[gpu_buffer.type](size)
    random.rand(host_buffer.unsafe_ptr(), size, min=-0.1, max=0.1)
    gpu_buffer.enqueue_copy_from(host_buffer)


fn enqueue_create_matrix[
    layout: LY,
    dtype: DType,
    randomize: Bool = False,
](ctx: DeviceContext) raises -> (
    DeviceBuffer[dtype],
    LayoutTensor[dtype, layout, MutableAnyOrigin],
):
    alias rows = layout.shape[0].value()
    alias cols = layout.shape[1].value()
    var b = enqueue_create_buf[dtype](ctx, rows * cols)

    @parameter
    if randomize:
        enqueue_randomize(ctx, b)

    t = enqueue_buf_to_tensor[layout](ctx, b)
    return b, t


fn enqueue_create_matrix[
    size: Int,
    *,
    dtype: DType,
    randomize: Bool = False,
](ctx: DeviceContext) raises -> (
    DeviceBuffer[dtype],
    LayoutTensor[dtype, Layout(size), MutableAnyOrigin],
):
    return enqueue_create_matrix[Layout(size), dtype, randomize](ctx)


fn enqueue_create_matrix[
    randomize: Bool = False,
](ctx: DeviceContext, like: LayoutTensor) raises -> (
    DeviceBuffer[like.dtype],
    LayoutTensor[like.dtype, like.layout, MutableAnyOrigin],
):
    alias rows = like.layout.shape[0].value()
    alias cols = like.layout.shape[1].value()
    var b = enqueue_create_buf[like.dtype](ctx, rows * cols)

    @parameter
    if randomize:
        enqueue_randomize(ctx, b)

    t = enqueue_buf_to_tensor(ctx, like, b)
    return b, t


fn enqueue_images_to_gpu_matrix[
    img_type: HasData & Copyable & Movable,
    layout: LY,
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

    ctx.synchronize()
    for pixel in range(pixels):
        for image in range(images_):
            control = Int(images[image].get_data()[pixel])
            local_tensor[pixel, image] = control

    buff.enqueue_copy_from(local_buff)


fn enqueue_create_labels[
    img_type: HasLabel & Copyable & Movable,
    ly: LY,
](
    ctx: DeviceContext,
    buff: DeviceBuffer,
    tensor: LayoutTensor[buff.type, ly],
    images: List[img_type],
) raises:
    alias dtype = buff.type
    local_buff = enqueue_create_host_buf[dtype](ctx, len(buff))
    local_buff = local_buff.enqueue_fill(0)
    local_tensor = LayoutTensor[dtype, tensor.layout](local_buff)

    if len(images) != len(buff):
        abort("Train data len didn't match")

    alias dim: Int = tensor.layout.shape[0].value()

    ctx.synchronize()
    for i in range(len(images)):
        local_tensor[i] = images[i].get_label()

    buff.enqueue_copy_from(local_buff)
