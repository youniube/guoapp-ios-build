#include "python_embed.h"
#include <string.h>
#include <wchar.h>
#include <stdint.h>
#ifdef _WIN32
#include <windows.h>
static HMODULE handle;
#define SYMBOL(name) GetProcAddress(handle, name)
#else
#include <dlfcn.h>
static void *handle;
#define SYMBOL(name) dlsym(handle, name)
#endif
static void *(*createconfig)(void);
static void (*freeconfig)(void *);
static int (*setstring)(void *, const char *, const char *);
static int (*setinteger)(void *, const char *, int64_t);
static int (*setlist)(void *, const char *, size_t, char *const *);
static int (*initialize)(void *);
static void *(*savethread)(void);
static int (*ensure)(void);
static void (*release)(int);
static int (*run)(const char *, void *);
static void *(*module)(const char *);
static void *(*dictionary)(void *);
static void *(*getitem)(void *, const char *);
static const char *(*utf8)(void *);
static void (*clearerror)(void);
static int ready;

int guo_python_initialize(const char *library, const char *home, const char *search) {
    if (ready) return 0;
#ifdef _WIN32
    int wide_count = MultiByteToWideChar(CP_UTF8, 0, library, -1, NULL, 0);
    wchar_t *filename = calloc(wide_count, sizeof(wchar_t));
    MultiByteToWideChar(CP_UTF8, 0, library, -1, filename, wide_count);
    handle = LoadLibraryExW(filename, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    free(filename);
#else
    handle = dlopen(library, RTLD_NOW | RTLD_GLOBAL);
#endif
    if (!handle) return 1;
#define LOAD(variable, symbol) *(void **)(&variable) = (void *)SYMBOL(symbol); if (!variable) return 2;
    LOAD(createconfig, "PyInitConfig_Create")
    LOAD(freeconfig, "PyInitConfig_Free")
    LOAD(setstring, "PyInitConfig_SetStr")
    LOAD(setinteger, "PyInitConfig_SetInt")
    LOAD(setlist, "PyInitConfig_SetStrList")
    LOAD(initialize, "Py_InitializeFromInitConfig")
    LOAD(savethread, "PyEval_SaveThread")
    LOAD(ensure, "PyGILState_Ensure")
    LOAD(release, "PyGILState_Release")
    LOAD(run, "PyRun_SimpleStringFlags")
    LOAD(module, "PyImport_AddModule")
    LOAD(dictionary, "PyModule_GetDict")
    LOAD(getitem, "PyDict_GetItemString")
    LOAD(utf8, "PyUnicode_AsUTF8")
    LOAD(clearerror, "PyErr_Clear")
#undef LOAD
    void *config = createconfig();
    if (!config) return 3;
    char *paths = malloc(strlen(search) + 1);
    if (!paths) { freeconfig(config); return 3; }
    strcpy(paths, search);
    char *entries[32];
    size_t count = 0;
#ifdef _WIN32
    const char separator = ';';
#else
    const char separator = ':';
#endif
    char *start = paths;
    for (char *cursor = paths; ; cursor++) {
        if (*cursor == separator || *cursor == '\0') {
            char end = *cursor;
            *cursor = '\0';
            if (count >= 32) { free(paths); freeconfig(config); return 3; }
            entries[count++] = start;
            start = cursor + 1;
            if (!end) break;
        }
    }
    int status = setstring(config, "home", home);
    status |= setinteger(config, "module_search_paths_set", 1);
    status |= setlist(config, "module_search_paths", count, entries);
    status |= setinteger(config, "install_signal_handlers", 0);
    status |= setinteger(config, "write_bytecode", 0);
    status |= setinteger(config, "buffered_stdio", 0);
    status |= setinteger(config, "utf8_mode", 1);
    status |= setinteger(config, "site_import", 0);
    if (!status) status = initialize(config);
    free(paths);
    freeconfig(config);
    if (status) return 4;
    savethread();
    ready = 1;
    return 0;
}

char *guo_python_execute(const char *code) {
    if (!ready) return NULL;
    int state = ensure();
    char *result = NULL;
    if (run(code, NULL) == 0) {
        void *main = module("__main__");
        void *value = main ? getitem(dictionary(main), "_guo_result") : NULL;
        const char *value_utf8 = value ? utf8(value) : NULL;
        if (value_utf8) {
            size_t length = strlen(value_utf8);
            result = malloc(length + 1);
            if (result) memcpy(result, value_utf8, length + 1);
        }
    }
    clearerror();
    release(state);
    return result;
}
