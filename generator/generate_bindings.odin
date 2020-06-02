package generate

import "core:fmt"
import "core:os"
import "core:strings"
import "./bindgen"
// import "core:encoding/json"
import "./preprocessed/aux_data"

USE_MATH_TYPES :: true;

when os.OS == "windows" {
    import "core:sys/win32"

    mkdir_if_not_exist :: proc(dir: string) -> os.Errno {
        dir_wstr := win32.utf8_to_wstring(dir, context.temp_allocator);
        if win32.Bool(false) == win32.create_directory_w(dir_wstr, nil) do return os.Errno(win32.get_last_error());
        return os.ERROR_NONE;
    }

    preprocess_source :: proc(path_to_source_file: string, path_to_output_file: string) -> bool {
        cmdline := strings.clone_to_cstring(fmt.tprint("cmd /c cl /EP ", path_to_source_file, " > ", path_to_output_file), context.temp_allocator);

        startup_info: win32.Startup_Info = { cb = size_of(win32.Startup_Info) };
        process_information: win32.Process_Information;
        if ok := win32.create_process_a(nil, cmdline, nil, nil, false, 0, nil,  nil, &startup_info, &process_information); !ok {
            fmt.eprintln("could not invoke build script");
            return false;
        }

        if win32.WAIT_OBJECT_0 != win32.wait_for_single_object(process_information.process, win32.INFINITE) {
            fmt.eprintln("ERROR invoking build batch file");
            return false;
        }

        output, ok := os.read_entire_file(path_to_output_file);
        if !ok {
            fmt.eprintln("cl.exe preprocessor did not output to ", path_to_output_file);
        }
        output_lines := strings.split(cast(string)output, "\n");

        trimmed_lines: [dynamic]string;
        for line in output_lines {
            line_trimmed := strings.trim_space(line);
            if len(line_trimmed) == 0 do continue;
            append(&trimmed_lines, fmt.tprintf("%s\n", line_trimmed));
        }
        trimmed_output := strings.join(trimmed_lines[:], "", context.temp_allocator);

        os.write_entire_file(path_to_output_file, transmute([]u8)trimmed_output);

        // TODO: something like win32.destroy_handle(process_information.process);
        return true;
    }
}

default_generator_options :: proc() -> bindgen.GeneratorOptions {
    options : bindgen.GeneratorOptions;

    using options;

    // odin default casing
    variableCase = .Snake;
    functionCase = .Snake;
    pseudoTypeCase = .Pascal;

    when USE_MATH_TYPES {
        typeReplacements["Vector2"] = "linalg.Vector2";
        typeReplacements["Vector3"] = "linalg.Vector3";
        typeReplacements["Vector4"] = "linalg.Vector4";
        typeReplacements["Matrix"] = "linalg.Matrix4";
    }

    return options;
}

generate_raylib_bindings :: proc() {
    options := default_generator_options();
    when USE_MATH_TYPES do options.odin_includes = []string {
        "core:math/linalg",
    };
    options.enumValuePrefixes = {
        "FLAG_", "LOG_", "KEY_", "GAMEPAD_", "MOUSE_", "LOC_",
        "UNIFORM_", "MAP_", "FONT_", "GESTURE_", "CAMERA_", "HMD_",
        "BLEND_", "FILTER_",
    };

    {
        using options.parserOptions;
        customExpressionHandlers["CLITERAL"] = cliteral_handler;
        customExpressionHandlers["Font"] = font_handler;
        customExpressionHandlers["Camera3D"] = camera3d_handler;
        ignoredTokens = []string{"RLAPI"};
    }

    args_map : bindgen.Enum_Args_Map = aux_data.get_enum_args();

    mkdir_if_not_exist("raylib");
    mkdir_if_not_exist("raylib/bridge");
    mkdir_if_not_exist("raylib/types");
    
    outputFile := "raylib/raylib_bindings.odin";
    typesFile  := "raylib/types/raylib_types.odin";
    bridgeFile := "raylib/bridge/raylib_bridge.odin";

    preprocessed_target_file := "./generator/preprocessed/raylib-preprocessed.h";
    preprocess_source("ext/raylib/include/raylib.h", preprocessed_target_file);

    ok := bindgen.generate(
        packageName = "raylib",
        foreignLibrary = "raylib.lib",
        outputFile = outputFile,
        typesFile = typesFile,
        bridgeFile = bridgeFile,
        headerFiles = []string{ preprocessed_target_file },
        options_= options,
        enum_args_map = args_map,
    );

    if ok {
        fmt.println("wrote", outputFile);
        fmt.println("wrote", typesFile);
        fmt.println("wrote", bridgeFile);
    }
}

generate_raygui_bindings :: proc() {
    options := default_generator_options();
    options.odin_using_includes = []string{ "../../raylib/types", };
    when USE_MATH_TYPES do options.odin_includes = []string{
        "core:math/linalg"
    };

    {
        using options.parserOptions;
        ignoredTokens = []string{};
        customExpressionHandlers["CLITERAL"] = cliteral_handler;
        customHandlers["RAYGUIDEF"] = rayguidef_handler;
        customExpressionHandlers["__declspec"] = declspec_handler;
        ignoredDefines = []string{"RAYGUIDEF", "CLITERAL"};
    }

    mkdir_if_not_exist("ext/raygui");
    mkdir_if_not_exist("ext/raygui/types");
    mkdir_if_not_exist("ext/raygui/bridge");
    
    outputFile := "ext/raygui/raygui_bindings.odin";
    typesFile  := "ext/raygui/types/raygui_types.odin";
    bridgeFile := "ext/raygui/bridge/raygui_bridge.odin";
    args_map : bindgen.Enum_Args_Map;

    ok := bindgen.generate(
        packageName = "raygui",
        foreignLibrary = "raygui.lib",
        outputFile = outputFile,
        typesFile = typesFile,
        bridgeFile = bridgeFile,
        headerFiles = []string{"./ext/raygui/raygui-preprocessed.h"},
        options_ = options,
        enum_args_map = args_map,
    );

    if ok {
        fmt.println("wrote", outputFile);
        fmt.println("wrote", typesFile);
        fmt.println("wrote", bridgeFile);
    }

}

generate_raymath_bindings :: proc() {
    options := default_generator_options();
    options.odin_using_includes = []string{ "../../raylib/types", };
    {
        using options.parserOptions;
        ignoredTokens = []string{};
        customHandlers["RMDEF"] =  proc(data: ^bindgen.ParserData) {
            bindgen.check_and_eat_token(data, "RMDEF");
        };
        customExpressionHandlers["__declspec"] = declspec_handler;
        ignoredDefines = []string{"RMDEF",
            "PI", "DEG2RAD", "RAD2DEG", // these are already provided by raylib.h
        };
    }

    mkdir_if_not_exist("ext/raymath");
    mkdir_if_not_exist("ext/raymath/types");
    mkdir_if_not_exist("ext/raymath/bridge");
    
    outputFile := "ext/raymath/raymath_bindings.odin";
    typesFile  := "ext/raymath/types/raymath_types.odin";
    bridgeFile := "ext/raymath/bridge/raymath_bridge.odin";
    args_map : bindgen.Enum_Args_Map;

    if ok := bindgen.generate(
        packageName = "raymath",
        foreignLibrary = "raymath.lib",
        outputFile = outputFile,
        typesFile = typesFile,
        bridgeFile = bridgeFile,
        headerFiles = []string{"./ext/raymath/raymath-preprocessed.h"},
        options_ = options,
        enum_args_map = args_map,
    ); ok {
        fmt.println("wrote", outputFile);
        fmt.println("wrote", typesFile);
        fmt.println("wrote", bridgeFile);
    }
}

generate_physac_bindings :: proc() {
    options := default_generator_options();
    options.odin_using_includes = []string{ "../../raylib/types", };
    {
        using options.parserOptions;
        ignoredTokens = []string{};
        customHandlers["PHYSACDEF"] =  proc(data: ^bindgen.ParserData) {
            bindgen.check_and_eat_token(data, "PHYSACDEF");
        };
        ignoredDefines = []string{"PHYSACDEF" };
    }

    mkdir_if_not_exist("ext/physac");
    mkdir_if_not_exist("ext/physac/types");
    mkdir_if_not_exist("ext/physac/bridge");
    
    outputFile := "ext/physac/physac_bindings.odin";
    typesFile  := "ext/physac/types/physac_types.odin";
    bridgeFile := "ext/physac/bridge/physac_bridge.odin";
    args_map : bindgen.Enum_Args_Map;

    if ok := bindgen.generate(
        packageName = "physac",
        foreignLibrary = "physac.lib",
        outputFile = outputFile,
        typesFile = typesFile,
        bridgeFile = bridgeFile,
        headerFiles = []string{"./ext/physac/physac-preprocessed.h"},
        options_ = options,
        enum_args_map = args_map,
    ); ok {
        fmt.println("wrote", outputFile);
        fmt.println("wrote", typesFile);
        fmt.println("wrote", bridgeFile);
    }
}

generate_chipmunk_bindings :: proc() {
    options := default_generator_options();
    options.functionPrefixes = []string { "cp_" };
    //options.odin_using_includes = []string{ "../../raylib/types", };
    {
        using options.parserOptions;
        //ignoredTokens = []string{};
        //customHandlers["PHYSACDEF"] =  proc(data: ^bindgen.ParserData) {
            //bindgen.check_and_eat_token(data, "PHYSACDEF");
        //};
        //ignoredDefines = []string{"PHYSACDEF" };
    }

    options.functionPrefixes = { "cp", };
    options.pseudoTypePrefixes = { "cp", };
    options.enumValuePrefixes = { "CP_", "BODY_TYPE_", "SPACE_DEBUG_DRAW_", };

    mkdir_if_not_exist("ext/chipmunk");
    mkdir_if_not_exist("ext/chipmunk/types");
    mkdir_if_not_exist("ext/chipmunk/bridge");
    
    outputFile := "ext/chipmunk/chipmunk_bindings.odin";
    typesFile  := "ext/chipmunk/types/chipmunk_types.odin";
    bridgeFile := "ext/chipmunk/bridge/chipmunk_bridge.odin";
    args_map : bindgen.Enum_Args_Map;

    if ok := bindgen.generate(
        packageName = "chipmunk",
        foreignLibrary = "chipmunk.lib",
        outputFile = outputFile,
        typesFile = typesFile,
        bridgeFile = bridgeFile,
        headerFiles = []string{"./ext/Chipmunk2D/AmalgatedChipmunk.h"},
        options_ = options,
        enum_args_map = args_map,
    ); ok {
        fmt.println("wrote", outputFile);
        fmt.println("wrote", typesFile);
        fmt.println("wrote", bridgeFile);
    }
}

main :: proc() {
    generate_raylib_bindings();
    generate_raygui_bindings();
    generate_raymath_bindings();
    generate_physac_bindings();
    generate_chipmunk_bindings();
}

declspec_handler :: proc(data: ^bindgen.ParserData) -> bindgen.LiteralValue
{
    bindgen.check_and_eat_token(data, "__declspec");
    bindgen.eat_line(data);

    return "";
}

cliteral_handler :: proc(data: ^bindgen.ParserData) -> bindgen.LiteralValue
{
    bindgen.check_and_eat_token(data, "CLITERAL");
    bindgen.check_and_eat_token(data, "{");
    r := bindgen.evaluate_i64(data);
    bindgen.check_and_eat_token(data, ",");
    g := bindgen.evaluate_i64(data);
    bindgen.check_and_eat_token(data, ",");
    b := bindgen.evaluate_i64(data);
    bindgen.check_and_eat_token(data, ",");
    a := bindgen.evaluate_i64(data);
    bindgen.check_and_eat_token(data, "}");
    data.defining_node.is_variable = true;
    return fmt.tprintf("Color {{ %d, %d, %d, %d }}", r, g, b, a);
}

macro_make_version :: proc(data : ^bindgen.ParserData) -> bindgen.LiteralValue {
    bindgen.check_and_eat_token(data, "VK_MAKE_VERSION");
    bindgen.check_and_eat_token(data, "(");
    major := bindgen.evaluate_i64(data);
    bindgen.check_and_eat_token(data, ",");
    minor := bindgen.evaluate_i64(data);
    bindgen.check_and_eat_token(data, ",");
    patch := bindgen.evaluate_i64(data);
    bindgen.check_and_eat_token(data, ")");

    return (((major) << 22) | ((minor) << 12) | (patch));
}

rayguidef_handler :: proc(data: ^bindgen.ParserData) {
    bindgen.check_and_eat_token(data, "RAYGUIDEF");
}

color_handler :: proc(data: ^bindgen.ParserData) -> bindgen.LiteralValue {
    bindgen.check_and_eat_token(data, "Color"); return "Color";
}

font_handler :: proc(data: ^bindgen.ParserData) -> bindgen.LiteralValue {
    bindgen.check_and_eat_token(data, "Font"); return "Font";
}

camera3d_handler :: proc(data: ^bindgen.ParserData) -> bindgen.LiteralValue {
    bindgen.check_and_eat_token(data, "Camera3D"); return "Camera3D";
}

_cliteral_handler :: proc(data: ^bindgen.ParserData) {
    bindgen.check_and_eat_token(data, "(");
    bindgen.parse_identifier(data);
    bindgen.check_and_eat_token(data, ")");
}


