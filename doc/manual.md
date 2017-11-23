# Titan Language Reference

## Types

### Basic Types

- `nil`
- `boolean`
- `integer`
- `float`
- `string`

### Arrays

Array types in Titan have the form `{ t }`, where `t` is any Titan type
(including other array types, so `{ { integer } }` is the type for an array of
arrays of integers, for example.

You can create an empty array with the `{}` expression: Titan will try to guess
the type of this array from the context where you are creating it.
For example, if you are assigning the new array to an array-typed variable, the
array will have the same type of the variable.
If you are passing the array as an argument to a function that expects an
array-type parameter, the new array will have the same type as the parameter.
If you are declaring a new variable with an explicit array type declaration,
the new array will have the type you declared.
The only time where no context is available is when you declaring a new
variable and you have not given a type to it; in that case the array will have
type `{ integer }`.

### Records

Records are nominal and should be declared in the top level, like the following
example.

    record Point
        x: float
        y: float
    end

    record Circle
        center: Point
        radius: float
    end

After the top level declaration, you may create records with the `.new`
constructor:

    local p = Point.new(1, 2)
    local c = Circle.new(p, 3.5)

You can access the fields with the dot operator:

    local a = p.x
    p.y = 2
