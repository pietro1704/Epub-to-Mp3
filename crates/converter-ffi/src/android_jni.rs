use super::*;
use jni::{
    objects::{GlobalRef, JClass, JObject, JString, JValue},
    sys::{jboolean, jint, jlong, jstring},
    JNIEnv, JavaVM,
};

include!("android_jni/platform_speech_callbacks.rs");
include!("android_jni/piper_and_book_entrypoints.rs");
include!("android_jni/audio_chunk_publication.rs");
include!("android_jni/conversion_entrypoints.rs");
include!("android_jni/model_catalog_entrypoints.rs");
include!("android_jni/model_installation_entrypoints.rs");
