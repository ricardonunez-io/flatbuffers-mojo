from .data_types import ValueType, is_be
from bit import byte_swap

alias BufPointer = UnsafePointer[UInt8]


struct FlxValue(Sized):
    var _bytes: BufPointer
    var _byte_width: UInt8
    var _parent_byte_width: UInt8
    var _type: ValueType

    @always_inline
    fn __init__(
        mut self,
        bytes: BufPointer,
        parent_byte_width: UInt8,
        packed_type: UInt8,
    ):
        self._bytes = bytes
        self._parent_byte_width = parent_byte_width
        self._byte_width = 1 << (packed_type & 3)
        self._type = ValueType(packed_type >> 2)

    @always_inline
    fn __init__(
        mut self,
        bytes: BufPointer,
        parent_byte_width: UInt8,
        byte_width: UInt8,
        type: ValueType,
    ):
        self._bytes = bytes
        self._parent_byte_width = parent_byte_width
        self._byte_width = byte_width
        self._type = type

    fn __init__(mut self, bytes: BufPointer, length: Int) raises:
        if length < 3:
            raise "Length should be at least 3, was: " + String(length)
        var parent_byte_width = bytes[length - 1]
        var packed_type = bytes[length - 2]
        var offset = length - int(parent_byte_width) - 2
        self._bytes = bytes.offset(offset)
        self._parent_byte_width = parent_byte_width
        self._byte_width = 1 << (packed_type & 3)
        self._type = ValueType(packed_type >> 2)

    fn __init__(mut self, bytes_and_length: (BufPointer, Int)) raises:
        var bytes = bytes_and_length.get[0, BufPointer]()
        var length = bytes_and_length.get[1, Int]()
        if length < 3:
            raise "Length should be at least 3, was: " + String(length)
        var parent_byte_width = bytes[length - 1]
        var packed_type = bytes[length - 2]
        var offset = length - int(parent_byte_width) - 2
        self._bytes = bytes.offset(offset)
        self._parent_byte_width = parent_byte_width
        self._byte_width = 1 << (packed_type & 3)
        self._type = ValueType(packed_type >> 2)

    fn __moveinit__(mut self, owned other: Self):
        self._bytes = other._bytes
        self._parent_byte_width = other._parent_byte_width
        self._byte_width = other._byte_width
        self._type = other._type

    @always_inline
    fn __len__(self) -> Int:
        if self.is_null():
            return 0
        if self.is_vec():
            var p = jump_to_indirect(self._bytes, self._parent_byte_width)
            return read_uint(
                p.offset(-int(self._byte_width)), self._byte_width
            ) if not self._type.is_fixed_typed_vector() else self._type.fixed_typed_vector_element_size()
        if self._type == ValueType.String or self.is_blob() or self.is_map():
            var p = jump_to_indirect(self._bytes, self._parent_byte_width)
            return read_uint(p.offset(-int(self._byte_width)), self._byte_width)
        if self._type == ValueType.Key:
            var p = jump_to_indirect(self._bytes, self._parent_byte_width)
            var size = 0
            while p[size] != 0:
                size += 1
        return 1

    @always_inline
    fn is_null(self) -> Bool:
        return self._type == ValueType.Null

    @always_inline
    fn is_a[D: DType](self) -> Bool:
        return self._type == ValueType.of[D]()

    @always_inline
    fn is_map(self) -> Bool:
        return self._type == ValueType.Map

    @always_inline
    fn is_vec(self) -> Bool:
        return self._type.is_a_vector()

    @always_inline
    fn is_string(self) -> Bool:
        return self._type == ValueType.String or self._type == ValueType.Key

    @always_inline
    fn is_blob(self) -> Bool:
        return self._type == ValueType.Blob

    @always_inline
    fn is_int(self) -> Bool:
        return (
            self._type == ValueType.Int
            or self._type == ValueType.UInt
            or self._type == ValueType.IndirectInt
            or self._type == ValueType.IndirectUInt
        )

    @always_inline
    fn is_float(self) -> Bool:
        return (
            self._type == ValueType.Float
            or self._type == ValueType.IndirectFloat
        )

    @always_inline
    fn is_bool(self) -> Bool:
        return self._type == ValueType.Bool

    @always_inline
    fn get[D: DType](self) raises -> SIMD[D, 1]:
        if self._type != ValueType.of[D]():
            raise "Value is not of type " + D.__str__() + " type id: " + str(
                self._type.value
            )
        if sizeof[D]() != int(self._parent_byte_width):
            raise "Value byte width is " + str(
                self._parent_byte_width
            ) + " which does not conform with " + D.__str__()

        @parameter
        if is_be:
            return byte_swap(self._bytes.bitcast[D]()[0])
        else:
            return self._bytes.bitcast[D]()[0]

    @always_inline
    fn int(self) raises -> Int:
        if self._type == ValueType.Int:
            return read_int(self._bytes, self._parent_byte_width)
        if self._type == ValueType.UInt:
            return read_uint(self._bytes, self._parent_byte_width)
        if self._type == ValueType.IndirectInt:
            var p = jump_to_indirect(self._bytes, self._parent_byte_width)
            return read_int(p, self._byte_width)
        if self._type == ValueType.IndirectUInt:
            var p = jump_to_indirect(self._bytes, self._parent_byte_width)
            return read_uint(p, self._byte_width)
        raise "Type is not an int or uint, type id: " + str(self._type.value)

    @always_inline
    fn float(self) raises -> Float64:
        if self._type == ValueType.Float:
            return read_float(self._bytes, self._parent_byte_width)
        if self._type == ValueType.IndirectFloat:
            var p = jump_to_indirect(self._bytes, self._parent_byte_width)
            return read_float(p, self._byte_width)
        raise "Type is not a float, type id: " + str(self._type.value)

    @always_inline
    fn bool(self) raises -> Bool:
        if self._type == ValueType.Bool:
            return read_uint(self._bytes, self._parent_byte_width) == 1
        raise "Type is not a bool, type id: " + str(self._type.value)

    @always_inline
    fn string(self) raises -> String:
        if self._type == ValueType.String:
            var p = jump_to_indirect(self._bytes, self._parent_byte_width)
            var size = read_uint(
                p.offset(-int(self._byte_width)), self._byte_width
            )
            var size_width = self._byte_width
            while p[size] != 0:
                size_width <<= 1
                size = read_uint(p.offset(-int(size_width)), size_width)
            var p1 = UnsafePointer[UInt8].alloc(size + 1)
            memcpy(p1, p, size + 1)
            return String(p1, size + 1)
        if self._type == ValueType.Key:
            var p = jump_to_indirect(self._bytes, self._parent_byte_width)
            var size = 0
            while p[size] != 0:
                size += 1
            var p1 = UnsafePointer[UInt8].alloc(size + 1)
            memcpy(p1, p, size + 1)
            return String(p1, size + 1)
        raise "Type is not convertable to string, type id: " + str(
            self._type.value
        )

    @always_inline
    fn blob(self) raises -> (BufPointer, Int):
        if not self.is_blob():
            raise "Type is not blob, type id: " + str(self._type.value)
        var p = jump_to_indirect(self._bytes, self._parent_byte_width)
        var size = read_uint(p.offset(-int(self._byte_width)), self._byte_width)
        return (p, size)

    @always_inline
    fn vec(self) raises -> FlxVecValue:
        if not self._type.is_a_vector():
            raise "Value is not a vector. Type id: " + str(self._type.value)
        var p = jump_to_indirect(self._bytes, self._parent_byte_width)
        var size = read_uint(
            p.offset(-int(self._byte_width)), self._byte_width
        ) if not self._type.is_fixed_typed_vector() else self._type.fixed_typed_vector_element_size()
        return FlxVecValue(p, self._byte_width, self._type, size)

    @always_inline
    fn map(self) raises -> FlxMapValue:
        if self._type != ValueType.Map:
            raise "Value is not a map. Type id: " + str(self._type.value)
        var p = jump_to_indirect(self._bytes, self._parent_byte_width)
        var size = read_uint(p.offset(-int(self._byte_width)), self._byte_width)
        return FlxMapValue(p, self._byte_width, size)

    @always_inline
    fn has_key(self, key: String) raises -> Bool:
        if not self.is_map():
            return False
        return self.map().key_index(key) >= 0

    @always_inline
    fn __getitem__(self, index: Int) raises -> FlxValue:
        return self.vec()[index]

    @always_inline
    fn __getitem__(self, key: String) raises -> FlxValue:
        return self.map()[key]

    fn json(self) raises -> String:
        if self.is_null():
            return "null"
        if self.is_bool():
            return "true" if self.bool() else "false"
        if self.is_int():
            return self.int()
        if self.is_float():
            return self.float()
        if self.is_string():
            return '"' + self.string() + '"'
        if self.is_vec():
            var result: String = "["
            for i in range(self.__len__()):
                result += self[i].json()
                if i < self.__len__() - 1:
                    result += ","
            result += "]"
            return result
        if self.is_map():
            var result: String = "{"
            var map = self.map()
            var keys = map.keys()
            var values = map.values()
            for i in range(self.__len__()):
                result += '"' + keys[i].string() + '":' + values[i].json()
                if i < self.__len__() - 1:
                    result += ","
            result += "}"
            return result
        raise "Unexpected type id: " + str(self._type.value)


struct FlxVecValue(Sized):
    var _bytes: BufPointer
    var _byte_width: UInt8
    var _type: ValueType
    var _length: Int

    @always_inline
    fn __init__(
        mut self,
        bytes: BufPointer,
        byte_width: UInt8,
        type: ValueType,
        length: Int,
    ):
        self._bytes = bytes
        self._byte_width = byte_width
        self._type = type
        self._length = length

    @always_inline
    fn __len__(self) -> Int:
        return self._length

    @always_inline
    fn __getitem__(self, index: Int) raises -> FlxValue:
        if index < 0 or index >= self._length:
            raise "Bad index: " + String(index) + ". Lenght: " + String(
                self._length
            )
        if self._type.is_typed_vector():
            return FlxValue(
                self._bytes.offset(index * int(self._byte_width)),
                self._byte_width,
                1,
                self._type.typed_vector_element_type(),
            )
        if self._type.is_fixed_typed_vector():
            return FlxValue(
                self._bytes.offset(index * int(self._byte_width)),
                self._byte_width,
                1,
                self._type.fixed_typed_vector_element_type(),
            )
        if self._type == ValueType.Vector:
            var packed_type = self._bytes[
                self._length * int(self._byte_width) + index
            ]
            return FlxValue(
                self._bytes.offset(index * int(self._byte_width)),
                self._byte_width,
                packed_type,
            )
        raise "Is not an expected vector type. Type id: " + str(
            self._type.value
        )


struct FlxMapValue(Sized):
    var _bytes: BufPointer
    var _byte_width: UInt8
    var _length: Int

    @always_inline
    fn __init__(
        mut self,
        bytes: BufPointer,
        byte_width: UInt8,
        length: Int,
    ):
        self._bytes = bytes
        self._byte_width = byte_width
        self._length = length

    @always_inline
    fn __len__(self) -> Int:
        return self._length

    @always_inline
    fn __getitem__(self, key: String) raises -> FlxValue:
        var index = self.key_index(key)
        if index < 0:
            raise "Key " + key + " could not be found"
        return self.values()[index]

    @always_inline
    fn keys(self) -> FlxVecValue:
        var p1 = self._bytes.offset(int(self._byte_width) * -3)
        var p2 = jump_to_indirect(p1, self._byte_width)
        var byte_width = read_uint(
            p1.offset(int(self._byte_width)), self._byte_width
        )
        return FlxVecValue(p2, byte_width, ValueType.VectorKey, self._length)

    @always_inline
    fn values(self) -> FlxVecValue:
        return FlxVecValue(
            self._bytes, self._byte_width, ValueType.Vector, self._length
        )

    @always_inline
    fn key_index(self, key: String) raises -> Int:
        var a = key.unsafe_ptr()
        var keys = self.keys()
        var low = 0
        var high = self._length - 1
        while low <= high:
            var mid = (low + high) >> 1
            var mid_key = keys[mid]
            var b = jump_to_indirect(mid_key._bytes, mid_key._parent_byte_width)
            var diff = cmp(a, b, len(key) + 1)
            if diff == 0:
                return mid
            if diff < 0:
                high = mid - 1
            else:
                low = mid + 1
        return -1


@always_inline
fn jump_to_indirect(
    bytes: UnsafePointer[UInt8], byte_width: UInt8
) -> UnsafePointer[UInt8]:
    return bytes.offset(-read_uint(bytes, byte_width))


@always_inline
fn read_uint(bytes: DTypePointer[DType.uint8], byte_width: UInt8) -> Int:
    if byte_width < 4:
        if byte_width == 1:
            return int(bytes[0])
        else:

            @parameter
            if is_be:
                return int(byte_swap(bytes.bitcast[DType.uint16]()[0]))
            else:
                return int(bytes.bitcast[DType.uint16]()[0])
    else:
        if byte_width == 4:

            @parameter
            if is_be:
                return int(byte_swap(bytes.bitcast[DType.uint32]()[0]))
            else:
                return int(bytes.bitcast[DType.uint32]()[0])
        else:

            @parameter
            if is_be:
                return int(byte_swap(bytes.bitcast[DType.uint64]()[0]))
            else:
                return int(bytes.bitcast[DType.uint64]()[0])


@always_inline
fn read_int(bytes: DTypePointer[DType.uint8], byte_width: UInt8) -> Int:
    if byte_width < 4:
        if byte_width == 1:
            return int(bytes.bitcast[DType.int8]()[0])
        else:

            @parameter
            if is_be:
                return int(byte_swap(bytes.bitcast[DType.int16]()[0]))
            else:
                return int(bytes.bitcast[DType.int16]()[0])
    else:
        if byte_width == 4:

            @parameter
            if is_be:
                return int(byte_swap(bytes.bitcast[DType.int32]()[0]))
            else:
                return int(bytes.bitcast[DType.int32]()[0])
        else:

            @parameter
            if is_be:
                return int(byte_swap(bytes.bitcast[DType.int64]()[0]))
            else:
                return int(bytes.bitcast[DType.int64]()[0])


@always_inline
fn read_float(
    bytes: DTypePointer[DType.uint8], byte_width: UInt8
) raises -> Float64:
    if byte_width == 8:

        @parameter
        if is_be:
            return byte_swap(bytes.bitcast[DType.float64]()[0])
        else:
            return bytes.bitcast[DType.float64]()[0]
    if byte_width == 4:

        @parameter
        if is_be:
            return byte_swap(bytes.bitcast[DType.float32]()[0]).cast[
                DType.float64
            ]()
        else:
            return bytes.bitcast[DType.float32]()[0].cast[DType.float64]()
    if byte_width == 2:

        @parameter
        if is_be:
            return byte_swap(bytes.bitcast[DType.float16]()[0]).cast[
                DType.float64
            ]()
        else:
            return bytes.bitcast[DType.float16]()[0].cast[DType.float64]()
    raise "Unexpected byte width: " + str(byte_width)


@always_inline
fn cmp(
    a: DTypePointer[DType.uint8], b: DTypePointer[DType.uint8], length: Int
) -> Int:
    for i in range(length):
        var diff = int(a[i]) - int(b[i])
        if diff != 0:
            return diff
    return 0
