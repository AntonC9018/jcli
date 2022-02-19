module jcli.argbinder.binder;

import jcli.introspect, jcli.core;

// import std.algorithm;
import std.meta;
import std.traits;
import std.range : ElementType;

enum Binder;
struct UseConverter(alias _conversionFunction)
{ 
    alias conversionFunction = _conversionFunction;
}
struct PreValidate(_validationFunctions...)
{
    alias validationFunctions = _validationFunctions;
}
struct PostValidate(_validationFunctions...)
{
    alias validationFunctions = _validationFunctions;
}

alias PreValidator = PreValidate!();
alias PostValidator = PostValidate!();

template bindArgument(Binders...)
{
    static foreach (Binder; Binders)
    {
        static assert(Parameters!Binder.length == 1
            && is(Parameters!Binder[0] : string),
            "The binder " ~ Binder.stringof ~ " cannot be invoked with a string argument.");
    }

    Result bindArgument
    (
        alias /* Common or Named or Positional info */ argumentInfo,
        TCommand
    )
    (
        ref TCommand command,
        string stringValue
    )
    {
        alias argumentFieldSymbol = getArgumentFieldSymbol!(TCommand, argumentInfo);
        alias preValidators       = getValidators!(argumentFieldSymbol, PreValidate);
        alias postValidators      = getValidators!(argumentFieldSymbol, PostValidate);

        static if (argumentInfo.flags.has(ArgFlags._aggregateBit))
            alias ArgumentType = ElementType!(typeof(argumentFieldSymbol));
        else
            alias ArgumentType = typeof(argumentFieldSymbol);
        
        alias conversionFunction = getConversionFunction!(argumentFieldSymbol, ArgumentType, Binders);

        static foreach (v; preValidators)
        {{
            const validationResult = v(stringValue);
            if (!validationResult.isOk)
                return fail!void(validationResult.error, validationResult.errorCode);
        }}

        ResultOf!ArgumentType conversionResult; // Declared here first in order for opAssign to be called.
        conversionResult = conversionFunction(stringValue);
        if (!conversionResult.isOk)
            return fail!void(conversionResult.error, conversionResult.errorCode);

        static foreach (v; postValidators)
        {{
            const validationResult = v(conversionResult.value);
            if (!validationResult.isOk)
                return fail!void(validationResult.error, validationResult.errorCode);
        }}

        static if (argumentInfo.flags.has(ArgFlags._aggregateBit))
            command.getArgumentFieldRef!argumentInfo ~= conversionResult.value;
        else
            command.getArgumentFieldRef!argumentInfo = conversionResult.value;

        return ok();
    }
}
unittest
{
    alias Dummy = ArgNamed;
    
    // no binders
    alias bind = bindArgument!();
    
    {
        struct S
        {
            @Dummy
            int a;
        }
        S s;
        enum a = getCommonArgumentInfo!(S.a);
        {
            const result = bind!a(s, "1");
            assert(result.isOk);
            assert(s.a == 1);
        }
        {
            const result = bind!a(s, "b");
            assert(result.isError);
            assert(s.a == 1);
        }
    }
    {
        struct S
        {
            @Dummy
            @(ArgConfig.aggregate)
            int[] a;
        }
        S s;
        enum a = getCommonArgumentInfo!(S.a);
        {
            const result = bind!a(s, "1");
            assert(result.isOk);
            assert(s.a == [1]);
        }
        {
            const result = bind!a(s, "2");
            assert(result.isOk);
            assert(s.a == [1, 2]);
        }
        {
            const result = bind!a(s, "b");
            assert(result.isError);
            assert(s.a == [1, 2]);
        }
    }
    {
        struct S
        {
            @Dummy
            Nullable!bool a;
        }
        S s;
        enum a = getCommonArgumentInfo!(S.a);
        {
            s.a = false;
            const result = bind!a(s, "null");
            assert(result.isError);
            assert(s.a == false);
        }
        {
            const result = bind!a(s, "true");
            assert(result.isOk);
            assert(s.a == true);
        }
        {
            const result = bind!a(s, "false");
            assert(result.isOk);
            assert(s.a == false);
        }
        {
            s.a = true;
            const result = bind!a(s, "kek");
            assert(result.isError);
            assert(s.a == true);
        }
    }
    {
        struct S
        {
            @Dummy
            @(PreValidate!(a => fail!void("")))
            int a;
        }
        S s;
        enum a = getCommonArgumentInfo!(S.a);
        {
            const result = bind!a(s, "1");
            assert(result.isError);
        }
    }
    {
        struct S
        {
            @Dummy
            @(PostValidate!(a => fail!void("")))
            int a;
        }
        S s;
        enum a = getCommonArgumentInfo!(S.a);
        {
            s.a = 9;
            const result = bind!a(s, "1");
            assert(result.isError);
            assert(s.a == 9);
        }
    }
    {
        struct S
        {
            @Dummy
            @(UseConverter!((string b) => ok("nope")))
            int a;
        }
        static assert(getUDAs!(S.a, UseConverter).length == 1);
        enum a = getCommonArgumentInfo!(S.a);
        static assert(!__traits(compiles, bind!(a, S)));
    }
    {
        struct S
        {
            @Dummy
            @(UseConverter!(b => ok(b ~ "lol")))
            string a;
        }
        enum a = getCommonArgumentInfo!(S.a);
        S s;
        {
            const result = bind!a(s, "1");
            assert(result.isOk);
            assert(s.a == "1lol");
        }
    }
}
unittest
{
    alias Dummy = ArgNamed;
    {

        struct S
        {
            @Dummy
            string a;
        }

        enum a = getCommonArgumentInfo!(S.a);
        S s;
        {
            static ResultOf!string binder(string input) { return ok(input ~ "kek"); }
            alias bind = bindArgument!(binder);
            const result = bind!a(s, "1");
            assert(result.isOk);
            assert(s.a == "1kek");
        }
        {
            static ResultOf!string binder() { return ok("kek"); }
            static assert(!__traits(compiles, bindArgument!(binder)));
        }
    }
    
}

template bindArgumentAcrossModules(Modules...)
{
    alias ToBinder(alias M)         = getSymbolsByUDA!(M, Binder);
    alias Binders                   = staticMap!(ToBinder, Modules);
    alias bindArgumentAcrossModules = bindArgument!(Binders);
}

// template GetArgumentBinderInfo(
//     alias /* Common or Named or Positional info */ argumentInfo,
//     TCommand,
//     Binders...)
// {
    
// }

// This function should be used to convert the string 
// to the given value when all other options have failed.
import std.conv : to, ConvException;
ResultOf!T universalFallbackConverter(T)(string value)
    if (__traits(compiles, to!T))
{
    try 
        return ok(to!T(value));
    catch (ConvException exc)
        return fail!T(exc.msg); 
}

private:

template getValidators(alias ArgSymbol, alias ValidatorUDAType)
{
    alias result = AliasSeq!();
    static foreach (alias ValidatorUDA; getUDAs!(ArgSymbol, ValidatorUDAType))
        result = AliasSeq!(result, ValidatorUDA.validationFunctions);
    alias getValidators = result;
}

/// Binders must be functions returning ResultOf
template getConversionFunction(
    alias argumentFieldSymbol,
    
    // The argument type may be different from the actual field type
    // (currently only in the case when the argument has the aggregate flag). 
    ArgumentType,
    
    Binders...)
{
    import std.traits;
    alias FoundExplicitConverters = getUDAs!(argumentFieldSymbol, UseConverter);

    static assert(FoundExplicitConverters.length <= 1, "Only one @UseConverter may exist.");
    static if (FoundExplicitConverters.length == 0)
    {
        // There is no such thing as a to!(Nullable!int), for example,
        // but a Nullable!int can be created implicitly from an int.
        //
        // The whole point is, we need to convert into the underlying type 
        // and not into the outer Nullable type, because then to!ThatType will fail,
        // but the Nullable!T construction from a T won't.
        // 
        // So here we extract the inner type in case it is a Nullable.
        //
        // Note:
        // Nullable-like user types can be handled in user code via the use of Binders.
        // User-defined binders will match before the universal fallback converter (aka to!T).
        // 
        static if (is(ArgumentType : Nullable!T, T))
            alias ConversionType = T;
        else
            alias ConversionType = ArgumentType;

        enum isValidConversionFunction(alias f) = 
            __traits(compiles, { ArgumentType a = f!(ConversionType)("").value; })
            || __traits(compiles, { ArgumentType a = f("").value; });
        alias validConversionFunctions = Filter!(isValidConversionFunction, Binders);

        static if (validConversionFunctions.length == 0)
            alias getConversionFunction = universalFallbackConverter!ConversionType;
        else static if(__traits(compiles, Instantiate!(validConversionFunctions[0], ConversionType)))
            alias getConversionFunction = Instantiate!(validConversionFunctions[0], ConversionType);
        else
            alias getConversionFunction = validConversionFunctions[0];
    }
    else
    {
        alias getConversionFunction = FoundExplicitConverters[0].conversionFunction;
    }
}