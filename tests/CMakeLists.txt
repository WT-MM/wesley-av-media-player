# Test binaries stay at the top of the build tree, where scripts and docs
# look for them.
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${PROJECT_BINARY_DIR}")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${PROJECT_BINARY_DIR}")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${PROJECT_BINARY_DIR}")
# Tests compile production sources directly, so they must see the same build
# configuration as the targets those sources normally belong to.
if(WAM_NATIVE_BENCHMARK_TELEMETRY)
  add_compile_definitions(WAM_NATIVE_BENCHMARK_TELEMETRY=1)
endif()

# The tools that generate and inspect test media. Fixture generation needs GPL
# encoders, so this is a development FFmpeg, never the one a release ships
# (WAM_DEV_FFMPEG_EXECUTABLE, which the export tests exercise instead).
find_program(WAM_TEST_FFMPEG NAMES ffmpeg
  HINTS /opt/homebrew/bin /usr/local/bin /opt/local/bin)
find_program(WAM_TEST_FFPROBE NAMES ffprobe
  HINTS /opt/homebrew/bin /usr/local/bin /opt/local/bin)
if(NOT WAM_TEST_FFMPEG AND (APPLE OR WAM_BUILD_APP))
  message(FATAL_ERROR "The tests generate their media with FFmpeg; install it "
    "(brew install ffmpeg) or set WAM_TEST_FFMPEG")
endif()

# Generated media lives in the build tree, so parallel build trees never share
# or clobber one corpus.
set(WAMKIT_TEST_FIXTURE_DIR "${PROJECT_BINARY_DIR}/test-media/wamkit"
  CACHE PATH "Generated WAMKit test corpus")
if(APPLE)
  # Short A/V clips for the AVFoundation reader test and the WAMKit hosts.
  add_test(NAME wamkit_fixtures COMMAND "${Python3_EXECUTABLE}"
    "${PROJECT_SOURCE_DIR}/scripts/generate_wamkit_fixtures.py"
    --ffmpeg "${WAM_TEST_FFMPEG}" --output "${WAMKIT_TEST_FIXTURE_DIR}")
  set_tests_properties(wamkit_fixtures PROPERTIES
    FIXTURES_SETUP wamkit_media TIMEOUT 60)
endif()

add_executable(wam_caption_test
  caption_service_test.cpp
  ${PROJECT_SOURCE_DIR}/src/caption_service.cpp
  ${PROJECT_SOURCE_DIR}/src/caption_service.hpp
  ${PROJECT_SOURCE_DIR}/src/jobs.cpp
  ${PROJECT_SOURCE_DIR}/src/jobs.hpp)
target_link_libraries(wam_caption_test PRIVATE wam_caption_runtime)
target_include_directories(wam_caption_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
add_test(NAME caption_service COMMAND wam_caption_test)
# Its 150 ms watchdog deliberately races a real child process; do not let
# concurrent codec/packaging tests starve that child before it can start.
set_tests_properties(caption_service PROPERTIES RUN_SERIAL TRUE)
add_executable(wam_caption_backend_test caption_backend_test.cpp)
target_link_libraries(wam_caption_backend_test PRIVATE wam_caption_runtime)
target_include_directories(wam_caption_backend_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
add_test(NAME caption_backend COMMAND wam_caption_backend_test)
if(NOT WAM_HAS_SPEECH_ANALYZER)
  add_test(NAME caption_sdk_absent COMMAND wam_caption_backend_test --expect-unavailable)
endif()
if(UNIX)
  add_executable(wam_caption_flow_test caption_flow_test.cpp ${PROJECT_SOURCE_DIR}/src/caption_service.cpp ${PROJECT_SOURCE_DIR}/src/jobs.cpp)
  target_link_libraries(wam_caption_flow_test PRIVATE wam_caption_runtime)
  target_include_directories(wam_caption_flow_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
  add_test(NAME caption_flow COMMAND wam_caption_flow_test)
endif()
add_executable(wam_caption_proof caption_engine_proof.cpp ${PROJECT_SOURCE_DIR}/src/caption_service.cpp ${PROJECT_SOURCE_DIR}/src/jobs.cpp)
target_link_libraries(wam_caption_proof PRIVATE wam_caption_runtime)
target_include_directories(wam_caption_proof PRIVATE ${PROJECT_SOURCE_DIR}/src)

if(NOT WAM_BUILD_APP)
  return()
endif()

if((WAM_ENABLE_AVCODEC_STAGE OR WAM_ENABLE_AVFORMAT_STAGE) AND NOT WAM_TEST_FFPROBE)
  message(FATAL_ERROR "The native FFmpeg stage tests need ffprobe; set WAM_TEST_FFPROBE")
endif()

# Source lists shared with the production targets are relative to the root.
list(TRANSFORM WAM_QUICKLOOK_FRAME_SOURCES PREPEND "${PROJECT_SOURCE_DIR}/")
list(TRANSFORM WAM_MACOS_NATIVE_VIDEO_CORE_SOURCES PREPEND "${PROJECT_SOURCE_DIR}/")

if(APPLE AND WAM_ENABLE_MACOS_NATIVE_VIDEO)
  set(WAM_MACOS_NATIVE_VIDEO_METAL_MAPPER_SOURCES
    metal_frame_mapper.hpp
    metal_frame_mapper.mm)
  add_executable(wam_native_session_factory_test native_session_factory_test.mm)
  target_link_libraries(wam_native_session_factory_test PRIVATE wam_macos_native_session_system)
  add_test(NAME native_session_factory COMMAND wam_native_session_factory_test)
  add_executable(wam_macos_video_service_identity_test macos_video_service_identity_test.cpp)
  target_include_directories(wam_macos_video_service_identity_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
  target_compile_features(wam_macos_video_service_identity_test PRIVATE cxx_std_20)
  add_test(NAME macos_video_service_identity COMMAND wam_macos_video_service_identity_test)
  add_executable(wam_native_retirement_test native_retirement_test.mm)
  target_link_libraries(wam_native_retirement_test PRIVATE wam_macos_native_session_system)
  add_test(NAME native_retirement COMMAND wam_native_retirement_test)
  set_tests_properties(native_retirement PROPERTIES TIMEOUT 10)
  add_executable(wam_native_owner_embedding_test native_owner_embedding_test.mm)
  target_link_libraries(wam_native_owner_embedding_test PRIVATE wam_macos_native_session_system)
  add_test(NAME native_owner_embedding COMMAND wam_native_owner_embedding_test)
  add_executable(wam_native_layer_embedding_test native_layer_embedding_test.mm)
  target_compile_options(wam_native_layer_embedding_test PRIVATE -fobjc-arc)
  target_link_libraries(wam_native_layer_embedding_test PRIVATE wam_macos_native_layer)
  add_test(NAME native_layer_embedding COMMAND wam_native_layer_embedding_test)
endif()

if(APPLE AND WAM_BUILD_QUICKLOOK_APPEX)
  add_executable(wam_quicklook_thumbnail_frame_test
    quicklook_thumbnail_frame_test.mm
    ${WAM_QUICKLOOK_FRAME_SOURCES})
  set_target_properties(wam_quicklook_thumbnail_frame_test PROPERTIES
    LINKER_LANGUAGE OBJCXX
    AUTOMOC OFF AUTOUIC OFF AUTORCC OFF)
  target_include_directories(wam_quicklook_thumbnail_frame_test PRIVATE
    ${PROJECT_SOURCE_DIR}/src "${PROJECT_SOURCE_DIR}")
  target_compile_features(wam_quicklook_thumbnail_frame_test PRIVATE
    cxx_std_20)
  target_compile_options(wam_quicklook_thumbnail_frame_test PRIVATE
    "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
    -Wall -Wextra -Wpedantic)
  target_link_libraries(wam_quicklook_thumbnail_frame_test PRIVATE
    wam_native_core
    "${WAM_COREFOUNDATION_FRAMEWORK}"
    "${WAM_COREGRAPHICS_FRAMEWORK}"
    "${WAM_COREMEDIA_FRAMEWORK}"
    "${WAM_COREVIDEO_FRAMEWORK}"
    "${WAM_FOUNDATION_FRAMEWORK}"
    "${WAM_IMAGEIO_FRAMEWORK}"
    "${WAM_VIDEOTOOLBOX_FRAMEWORK}")
  # No media fixture in the tree is a Matroska or transport stream, so the
  # argument-free run is a contract check: a missing file must fail closed
  # with a reason rather than crashing, hanging, or handing back a frame.
  add_test(NAME macos_quicklook_thumbnail_frame
    COMMAND wam_quicklook_thumbnail_frame_test)
  set_tests_properties(macos_quicklook_thumbnail_frame PROPERTIES
    TIMEOUT 30)
endif()

if(APPLE)
  add_test(NAME macos_bundle_lazy_mpv_transaction
    COMMAND /bin/zsh
      "${PROJECT_SOURCE_DIR}/tests/bundle_macos_lazy_mpv_seed_test.zsh")
  set_tests_properties(macos_bundle_lazy_mpv_transaction PROPERTIES
    TIMEOUT 120)
  add_test(NAME macos_release_notarize_transaction
    COMMAND /bin/zsh
      "${PROJECT_SOURCE_DIR}/tests/release_macos_notarize_test.zsh")
  set_tests_properties(macos_release_notarize_transaction PROPERTIES
    TIMEOUT 90)
endif()
add_test(NAME msys2_pkgconfig_paths
  COMMAND ${CMAKE_COMMAND} -P
    ${PROJECT_SOURCE_DIR}/tests/cmake/msys2_pkgconfig_paths_test.cmake)

if(TARGET wam_native_core)
  add_executable(wam_native_exact_embedding_time_test native_exact_embedding_time_test.cpp)
  target_link_libraries(wam_native_exact_embedding_time_test PRIVATE wam_native_core)
  add_test(NAME native_exact_embedding_time COMMAND wam_native_exact_embedding_time_test)

  add_executable(wam_native_media_source_test
    native_media_source_test.cpp)
  target_link_libraries(
    wam_native_media_source_test PRIVATE wam_native_core)
  add_test(NAME native_media_source COMMAND wam_native_media_source_test)

  add_executable(wam_native_media_backend_test
    native_media_backend_test.cpp)
  target_link_libraries(
    wam_native_media_backend_test PRIVATE wam_native_core)
  add_test(NAME native_media_backend COMMAND wam_native_media_backend_test)

  add_executable(wam_media_container_routing_test
    media_container_routing_test.cpp)
  target_link_libraries(
    wam_media_container_routing_test PRIVATE wam_native_core)
  add_test(NAME media_container_routing
    COMMAND wam_media_container_routing_test)

  add_executable(wam_matroska_ebml_test
    matroska_ebml_test.cpp)
  target_link_libraries(wam_matroska_ebml_test PRIVATE wam_native_core)
  add_test(NAME matroska_ebml COMMAND wam_matroska_ebml_test)

  add_executable(wam_subtitle_text_test
    subtitle_text_test.cpp)
  target_link_libraries(wam_subtitle_text_test PRIVATE wam_native_core)
  add_test(NAME subtitle_text COMMAND wam_subtitle_text_test)

  add_executable(wam_embedded_captions_test
    embedded_captions_test.cpp)
  target_link_libraries(wam_embedded_captions_test PRIVATE wam_native_core)
  add_test(NAME embedded_captions COMMAND wam_embedded_captions_test)

  add_executable(wam_subtitle_bitmap_test
    subtitle_bitmap_test.cpp)
  target_link_libraries(wam_subtitle_bitmap_test PRIVATE wam_native_core)
  add_test(NAME subtitle_bitmap COMMAND wam_subtitle_bitmap_test)

  add_executable(wam_matroska_subtitles_test
    matroska_subtitles_test.cpp)
  target_link_libraries(wam_matroska_subtitles_test PRIVATE wam_native_core)
  add_test(NAME matroska_subtitles COMMAND wam_matroska_subtitles_test)

  add_executable(wam_matroska_aac_test
    matroska_aac_test.cpp)
  target_link_libraries(wam_matroska_aac_test PRIVATE wam_native_core)
  add_test(NAME matroska_aac COMMAND wam_matroska_aac_test)

  add_executable(wam_matroska_opus_test
    matroska_opus_test.cpp)
  target_link_libraries(wam_matroska_opus_test PRIVATE wam_native_core)
  add_test(NAME matroska_opus COMMAND wam_matroska_opus_test)

  add_executable(wam_matroska_vorbis_test
    matroska_vorbis_test.cpp)
  target_link_libraries(wam_matroska_vorbis_test PRIVATE wam_native_core)
  add_test(NAME matroska_vorbis COMMAND wam_matroska_vorbis_test)

  add_executable(wam_matroska_ac3_test
    matroska_ac3_test.cpp)
  target_link_libraries(wam_matroska_ac3_test PRIVATE wam_native_core)
  add_test(NAME matroska_ac3 COMMAND wam_matroska_ac3_test)

  add_executable(wam_audio_downmix_test
    audio_downmix_test.cpp)
  target_link_libraries(wam_audio_downmix_test PRIVATE wam_native_core)
  add_test(NAME audio_downmix COMMAND wam_audio_downmix_test)

  add_executable(wam_adpcm_decoder_test adpcm_decoder_test.cpp)
  target_link_libraries(wam_adpcm_decoder_test PRIVATE wam_native_core)
  add_test(NAME adpcm_decoder COMMAND wam_adpcm_decoder_test)

  add_executable(wam_audio_codec_timing_test
    audio_codec_timing_test.cpp)
  target_link_libraries(wam_audio_codec_timing_test PRIVATE wam_native_core)
  add_test(NAME audio_codec_timing COMMAND wam_audio_codec_timing_test)

  add_executable(wam_native_audio_sample_rates_test
    native_audio_sample_rates_test.cpp
    ${PROJECT_SOURCE_DIR}/src/platform/macos/native_audio_sample_rates.hpp)
  target_link_libraries(wam_native_audio_sample_rates_test PRIVATE
    wam_native_core)
  add_test(NAME native_audio_sample_rates
    COMMAND wam_native_audio_sample_rates_test)

  add_executable(wam_native_coverage_admission_test
    native_coverage_admission_test.cpp)
  target_link_libraries(wam_native_coverage_admission_test PRIVATE wam_native_core)
  add_test(NAME native_coverage_admission COMMAND wam_native_coverage_admission_test)

  add_executable(wam_media_codec_facts_test
    media_codec_facts_test.cpp)
  target_link_libraries(wam_media_codec_facts_test PRIVATE wam_native_core)
  add_test(NAME media_codec_facts COMMAND wam_media_codec_facts_test)

  add_executable(wam_matroska_flac_test
    matroska_flac_test.cpp)
  target_link_libraries(wam_matroska_flac_test PRIVATE wam_native_core)
  add_test(NAME matroska_flac COMMAND wam_matroska_flac_test)

  add_executable(wam_matroska_mpeg_audio_test
    matroska_mpeg_audio_test.cpp)
  target_link_libraries(wam_matroska_mpeg_audio_test PRIVATE wam_native_core)
  add_test(NAME matroska_mpeg_audio COMMAND wam_matroska_mpeg_audio_test)

  add_executable(wam_matroska_demuxer_test
    matroska_demuxer_test.cpp)
  target_link_libraries(wam_matroska_demuxer_test PRIVATE wam_native_core)
  add_test(NAME matroska_demuxer COMMAND wam_matroska_demuxer_test)

  add_executable(wam_mpegts_demuxer_test
    mpegts_demuxer_test.cpp)
  target_link_libraries(wam_mpegts_demuxer_test PRIVATE wam_native_core)
  add_test(NAME mpegts_demuxer COMMAND wam_mpegts_demuxer_test)
  set(WAM_MPEGTS_FIXTURE_DIR "${PROJECT_BINARY_DIR}/mpegts-fixtures-v1")
  add_test(NAME mpegts_fixture_setup
    COMMAND "${Python3_EXECUTABLE}"
      "${PROJECT_SOURCE_DIR}/tests/prepare_mpegts_fixtures.py"
      --root "${WAM_MPEGTS_FIXTURE_DIR}" --ffmpeg "${WAM_TEST_FFMPEG}")
  set_tests_properties(mpegts_fixture_setup PROPERTIES
    FIXTURES_SETUP mpegts_corpus TIMEOUT 120)
  add_test(NAME mpegts_demuxer_integration
    COMMAND wam_mpegts_demuxer_test --integration)
  set_tests_properties(mpegts_demuxer_integration PROPERTIES
    FIXTURES_REQUIRED mpegts_corpus
    ENVIRONMENT "WAM_MPEGTS_FIXTURES=${WAM_MPEGTS_FIXTURE_DIR}")

  # This optional benchmark uses POSIX-only fixture I/O.
  if(APPLE)
    # Not built by default and not a ctest test; run it by hand with
    # `cmake --build build --target wam_matroska_demuxer_bench` and
    # `build/wam_matroska_demuxer_bench --quick`.
    add_executable(wam_matroska_demuxer_bench EXCLUDE_FROM_ALL
      ${PROJECT_SOURCE_DIR}/benchmarks/matroska_demuxer_bench.cpp)
    target_link_libraries(wam_matroska_demuxer_bench PRIVATE wam_native_core)
    target_compile_features(wam_matroska_demuxer_bench PRIVATE cxx_std_20)
    target_compile_options(wam_matroska_demuxer_bench PRIVATE
      -Wall -Wextra -Wpedantic)
  endif()

  add_executable(wam_video_codec_configuration_test
    video_codec_configuration_test.cpp)
  target_link_libraries(
    wam_video_codec_configuration_test PRIVATE wam_native_core)
  add_test(NAME video_codec_configuration
    COMMAND wam_video_codec_configuration_test)

  add_executable(wam_native_playback_contract_test
    native_playback_contract_test.cpp)
  target_link_libraries(
    wam_native_playback_contract_test PRIVATE wam_native_core)
  add_test(NAME native_playback_contract
    COMMAND wam_native_playback_contract_test)

  add_executable(wam_native_media_dispatcher_test
    native_media_dispatcher_test.cpp)
  target_link_libraries(
    wam_native_media_dispatcher_test PRIVATE wam_native_core)
  add_test(NAME native_media_dispatcher
    COMMAND wam_native_media_dispatcher_test)

  add_executable(wam_playback_router_test
    playback_router_test.cpp)
  target_link_libraries(wam_playback_router_test PRIVATE wam_native_core)
  add_test(NAME playback_router COMMAND wam_playback_router_test)

  # The clock's bounded publication-token domain is a compile-time test
  # seam; compile a complete private implementation rather than mixing it
  # with the production wam_native_core object.
  add_executable(wam_native_media_clock_test
    native_media_clock_test.cpp
    ${PROJECT_SOURCE_DIR}/src/media/native_media_clock.hpp
    ${PROJECT_SOURCE_DIR}/src/media/native_media_clock.cpp)
  target_include_directories(wam_native_media_clock_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
  target_link_libraries(wam_native_media_clock_test PRIVATE wam_native_core)
  target_compile_definitions(wam_native_media_clock_test PRIVATE
    WAM_NATIVE_MEDIA_CLOCK_TESTING=1)
  add_test(NAME native_media_clock COMMAND wam_native_media_clock_test)

  add_executable(wam_native_pcm_ring_test
    native_pcm_ring_test.cpp)
  target_link_libraries(wam_native_pcm_ring_test PRIVATE wam_native_core)
  add_test(NAME native_pcm_ring COMMAND wam_native_pcm_ring_test)

  # The render core's test hooks are compiled in only with
  # WAM_NATIVE_TEST_SEAMS; compile a private render core with them, as the
  # clock test does for its token domain.
  add_executable(wam_native_audio_render_core_test
    native_audio_render_core_test.cpp
    ${PROJECT_SOURCE_DIR}/src/media/native_audio_render_core.cpp)
  target_include_directories(wam_native_audio_render_core_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
  target_compile_definitions(wam_native_audio_render_core_test PRIVATE
    WAM_NATIVE_TEST_SEAMS=1)
  target_link_libraries(
    wam_native_audio_render_core_test PRIVATE wam_native_core)
  add_test(NAME native_audio_render_core
    COMMAND wam_native_audio_render_core_test)

  foreach(WAM_NATIVE_CORE_TEST_TARGET IN ITEMS
      wam_matroska_aac_test
      wam_matroska_ebml_test
      wam_subtitle_text_test
      wam_embedded_captions_test
      wam_subtitle_bitmap_test
      wam_matroska_subtitles_test
      wam_matroska_opus_test
      wam_matroska_vorbis_test
      wam_matroska_ac3_test
      wam_audio_downmix_test
      wam_audio_codec_timing_test
      wam_native_audio_sample_rates_test
      wam_media_codec_facts_test
      wam_matroska_flac_test
      wam_matroska_mpeg_audio_test
      wam_matroska_demuxer_test
      wam_mpegts_demuxer_test
      wam_video_codec_configuration_test
      wam_native_media_source_test
      wam_native_media_backend_test
      wam_native_playback_contract_test
      wam_native_media_dispatcher_test
      wam_playback_router_test
      wam_native_media_clock_test
      wam_native_pcm_ring_test
      wam_native_audio_render_core_test)
    target_compile_features(${WAM_NATIVE_CORE_TEST_TARGET} PRIVATE
      cxx_std_20)
    target_compile_options(${WAM_NATIVE_CORE_TEST_TARGET} PRIVATE
      -Wall -Wextra -Wpedantic)
  endforeach()
  set_tests_properties(
    matroska_aac
    matroska_ebml
    subtitle_text
    embedded_captions
    subtitle_bitmap
    matroska_subtitles
    matroska_opus
    matroska_vorbis
    matroska_ac3
    audio_downmix
    audio_codec_timing
    native_audio_sample_rates
    media_codec_facts
    matroska_flac
    matroska_mpeg_audio
    matroska_demuxer
    mpegts_demuxer
    video_codec_configuration
    native_media_source
    native_media_backend
    native_playback_contract
    native_media_dispatcher
    playback_router
    native_media_clock
    native_pcm_ring
    native_audio_render_core
    PROPERTIES TIMEOUT 10)
endif()

add_executable(wam_playback_policy_test playback_policy_test.cpp)
target_include_directories(wam_playback_policy_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
add_test(NAME playback_policy COMMAND wam_playback_policy_test)

add_executable(wam_launch_rules_test launch_rules_test.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/media_url.cpp ${PROJECT_SOURCE_DIR}/src/qt/media_url.hpp)
target_include_directories(wam_launch_rules_test PRIVATE ${PROJECT_SOURCE_DIR}/src ${PROJECT_SOURCE_DIR}/src/qt)
target_link_libraries(wam_launch_rules_test PRIVATE Qt6::Core)
add_test(NAME launch_rules COMMAND wam_launch_rules_test)

add_executable(wam_mpv_hwdec_interop_policy_test
  mpv_hwdec_interop_policy_test.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/mpv_hwdec_interop_policy.hpp)
target_include_directories(wam_mpv_hwdec_interop_policy_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
add_test(NAME mpv_hwdec_interop_policy
  COMMAND wam_mpv_hwdec_interop_policy_test)

add_executable(wam_jobs_test jobs_test.cpp ${PROJECT_SOURCE_DIR}/src/jobs.cpp ${PROJECT_SOURCE_DIR}/src/jobs.hpp)
target_include_directories(wam_jobs_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
add_test(NAME jobs COMMAND wam_jobs_test)

add_executable(wam_state_test
  state_store_test.cpp ${PROJECT_SOURCE_DIR}/src/state_store.cpp ${PROJECT_SOURCE_DIR}/src/state_store.hpp)
target_include_directories(wam_state_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
add_test(NAME state_store COMMAND wam_state_test)

# The pointer-scroll gesture model links no Qt at all, which is exactly why
# it is its own translation unit: normalization, axis lock and the 100%
# detent are decided there and proved here without a GUI.
add_executable(wam_scroll_gesture_test
  scroll_gesture_test.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/scroll_gesture.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/scroll_gesture.hpp)
target_include_directories(wam_scroll_gesture_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
target_compile_features(wam_scroll_gesture_test PRIVATE cxx_std_20)
target_compile_options(wam_scroll_gesture_test PRIVATE
  -Wall -Wextra -Wpedantic)
add_test(NAME scroll_gesture COMMAND wam_scroll_gesture_test)

add_executable(wam_player_controller_lazy_test
  player_controller_lazy_test.cpp
  ${PROJECT_SOURCE_DIR}/src/playback/mpv/mpv_api.cpp
  ${PROJECT_SOURCE_DIR}/src/playback/mpv/mpv_runtime_common.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/player_controller.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/player_controller.hpp
  ${PROJECT_SOURCE_DIR}/src/qt/app_settings.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/app_settings.hpp
  ${PROJECT_SOURCE_DIR}/src/qt/mpv_engine.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/mpv_engine.hpp
  ${PROJECT_SOURCE_DIR}/src/qt/subtitle_sources.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/subtitle_sources.hpp
  ${PROJECT_SOURCE_DIR}/src/qt/subtitle_bitmap_provider.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/subtitle_bitmap_provider.hpp
  ${PROJECT_SOURCE_DIR}/src/media/subtitle_text.cpp
  ${PROJECT_SOURCE_DIR}/src/media/matroska_subtitles.cpp
  ${PROJECT_SOURCE_DIR}/src/media/tx3g_text.cpp
  ${PROJECT_SOURCE_DIR}/src/media/mp4_subtitles.cpp
  ${PROJECT_SOURCE_DIR}/src/media/h264_caption_sei.cpp
  ${PROJECT_SOURCE_DIR}/src/media/cea608_decoder.cpp
  ${PROJECT_SOURCE_DIR}/src/media/live_caption_feed.cpp
  ${PROJECT_SOURCE_DIR}/src/media/subtitle_bitmap.cpp
  ${PROJECT_SOURCE_DIR}/src/media/subtitle_pgs.cpp
  ${PROJECT_SOURCE_DIR}/src/media/subtitle_vobsub.cpp
  ${PROJECT_SOURCE_DIR}/src/media/byte_source.cpp
  ${PROJECT_SOURCE_DIR}/src/media/matroska_ebml.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/scroll_gesture.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/scroll_gesture.hpp
  ${PROJECT_SOURCE_DIR}/src/qt/player_core.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/player_core_p.hpp
  ${PROJECT_SOURCE_DIR}/src/jobs.cpp
  ${PROJECT_SOURCE_DIR}/src/jobs.hpp
  ${PROJECT_SOURCE_DIR}/src/caption_service.cpp
  ${PROJECT_SOURCE_DIR}/src/caption_service.hpp)
target_link_libraries(wam_player_controller_lazy_test PRIVATE wam_caption_runtime $<TARGET_NAME_IF_EXISTS:wam_caption_prompt>)
target_include_directories(wam_player_controller_lazy_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
target_compile_definitions(wam_player_controller_lazy_test PRIVATE
  WAM_MPV_RUNTIME_TESTING=1)
target_link_libraries(wam_player_controller_lazy_test PRIVATE
  Qt6::Core
  Qt6::Gui
  Qt6::Quick
  Qt6::OpenGL
  ${WAM_MPV_INTEGRATION_TEST_TARGET}
  wam_mpv_runtime)
add_test(NAME player_controller_lazy COMMAND wam_player_controller_lazy_test)
set_tests_properties(player_controller_lazy PROPERTIES TIMEOUT 20)

add_executable(wam_player_core_render_context_permission_test
  player_core_render_context_permission_test.cpp
  ${PROJECT_SOURCE_DIR}/src/playback/mpv/mpv_api.cpp
  ${PROJECT_SOURCE_DIR}/src/playback/mpv/mpv_runtime_common.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/player_controller.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/player_controller.hpp
  ${PROJECT_SOURCE_DIR}/src/qt/app_settings.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/app_settings.hpp
  ${PROJECT_SOURCE_DIR}/src/qt/mpv_engine.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/mpv_engine.hpp
  ${PROJECT_SOURCE_DIR}/src/qt/subtitle_sources.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/subtitle_sources.hpp
  ${PROJECT_SOURCE_DIR}/src/qt/subtitle_bitmap_provider.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/subtitle_bitmap_provider.hpp
  ${PROJECT_SOURCE_DIR}/src/media/subtitle_text.cpp
  ${PROJECT_SOURCE_DIR}/src/media/matroska_subtitles.cpp
  ${PROJECT_SOURCE_DIR}/src/media/tx3g_text.cpp
  ${PROJECT_SOURCE_DIR}/src/media/mp4_subtitles.cpp
  ${PROJECT_SOURCE_DIR}/src/media/h264_caption_sei.cpp
  ${PROJECT_SOURCE_DIR}/src/media/cea608_decoder.cpp
  ${PROJECT_SOURCE_DIR}/src/media/live_caption_feed.cpp
  ${PROJECT_SOURCE_DIR}/src/media/subtitle_bitmap.cpp
  ${PROJECT_SOURCE_DIR}/src/media/subtitle_pgs.cpp
  ${PROJECT_SOURCE_DIR}/src/media/subtitle_vobsub.cpp
  ${PROJECT_SOURCE_DIR}/src/media/byte_source.cpp
  ${PROJECT_SOURCE_DIR}/src/media/matroska_ebml.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/scroll_gesture.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/scroll_gesture.hpp
  ${PROJECT_SOURCE_DIR}/src/qt/player_core.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/player_core_p.hpp
  ${PROJECT_SOURCE_DIR}/src/qt/render_lifecycle.hpp
  ${PROJECT_SOURCE_DIR}/src/qt/mpv_render_context_policy.hpp
  ${PROJECT_SOURCE_DIR}/src/jobs.cpp
  ${PROJECT_SOURCE_DIR}/src/jobs.hpp
  ${PROJECT_SOURCE_DIR}/src/caption_service.cpp
  ${PROJECT_SOURCE_DIR}/src/caption_service.hpp)
target_link_libraries(wam_player_core_render_context_permission_test PRIVATE wam_caption_runtime $<TARGET_NAME_IF_EXISTS:wam_caption_prompt>)
target_include_directories(
  wam_player_core_render_context_permission_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
target_compile_definitions(
  wam_player_core_render_context_permission_test PRIVATE
  WAM_MPV_RUNTIME_TESTING=1
  WAM_PLAYER_CORE_RENDER_CONTEXT_TESTING=1)
target_link_libraries(wam_player_core_render_context_permission_test PRIVATE
  Qt6::Core
  Qt6::Gui
  Qt6::Quick
  Qt6::OpenGL
  ${WAM_MPV_INTEGRATION_TEST_TARGET}
  wam_mpv_runtime)
add_test(NAME player_core_render_context_permission
  COMMAND wam_player_core_render_context_permission_test)
set_tests_properties(player_core_render_context_permission PROPERTIES
  TIMEOUT 30 SKIP_RETURN_CODE 77)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  set_tests_properties(player_controller_lazy player_core_render_context_permission PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
endif()

add_executable(wam_render_lifecycle_test
  render_lifecycle_test.cpp
  ${PROJECT_SOURCE_DIR}/src/qt/render_lifecycle.hpp)
target_include_directories(wam_render_lifecycle_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
add_test(NAME render_lifecycle COMMAND wam_render_lifecycle_test)

if(WAM_DEV_FFMPEG_EXECUTABLE AND WAM_TEST_FFPROBE)
  add_executable(wam_export_integration_test
    export_integration_test.cpp ${PROJECT_SOURCE_DIR}/src/jobs.cpp ${PROJECT_SOURCE_DIR}/src/jobs.hpp)
  target_include_directories(wam_export_integration_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
  if(APPLE)
    add_test(NAME export_presets COMMAND wam_export_integration_test
      "${WAM_DEV_FFMPEG_EXECUTABLE}" "${WAM_TEST_FFPROBE}" --all-presets)
  endif()
  add_test(NAME export_duration COMMAND wam_export_integration_test
    "${WAM_DEV_FFMPEG_EXECUTABLE}" "${WAM_TEST_FFPROBE}")
endif()

if(APPLE)
  string(REPLACE "." "\\." WAM_MACOS_DEPLOYMENT_TARGET_REGEX
    "${CMAKE_OSX_DEPLOYMENT_TARGET}")
  add_test(NAME macos_deployment_target
    COMMAND /usr/bin/otool -l "$<TARGET_FILE:wam>")
  set_tests_properties(macos_deployment_target PROPERTIES
    PASS_REGULAR_EXPRESSION
      "minos ${WAM_MACOS_DEPLOYMENT_TARGET_REGEX}")

  # Structural, unshown-window gate for the one native child owned by the
  # macOS stage. Compile the same controller/core closure as production so
  # MpvVideoItem is never tested against placeholder method definitions.
  add_executable(wam_mpv_video_item_native_host_test
    mpv_video_item_native_host_test.cpp
    ${PROJECT_SOURCE_DIR}/src/qt/mpv_video_item.cpp
    ${PROJECT_SOURCE_DIR}/src/qt/mpv_video_item.hpp
    ${PROJECT_SOURCE_DIR}/src/qt/player_controller.cpp
    ${PROJECT_SOURCE_DIR}/src/qt/player_controller.hpp
    ${PROJECT_SOURCE_DIR}/src/qt/app_settings.cpp
    ${PROJECT_SOURCE_DIR}/src/qt/app_settings.hpp
    ${PROJECT_SOURCE_DIR}/src/qt/mpv_engine.cpp
    ${PROJECT_SOURCE_DIR}/src/qt/mpv_engine.hpp
    ${PROJECT_SOURCE_DIR}/src/qt/subtitle_sources.cpp
    ${PROJECT_SOURCE_DIR}/src/qt/subtitle_sources.hpp
    ${PROJECT_SOURCE_DIR}/src/qt/subtitle_bitmap_provider.cpp
    ${PROJECT_SOURCE_DIR}/src/qt/subtitle_bitmap_provider.hpp
    ${PROJECT_SOURCE_DIR}/src/media/subtitle_text.cpp
    ${PROJECT_SOURCE_DIR}/src/media/matroska_subtitles.cpp
  ${PROJECT_SOURCE_DIR}/src/media/tx3g_text.cpp
  ${PROJECT_SOURCE_DIR}/src/media/mp4_subtitles.cpp
  ${PROJECT_SOURCE_DIR}/src/media/h264_caption_sei.cpp
  ${PROJECT_SOURCE_DIR}/src/media/cea608_decoder.cpp
  ${PROJECT_SOURCE_DIR}/src/media/live_caption_feed.cpp
    ${PROJECT_SOURCE_DIR}/src/media/subtitle_bitmap.cpp
    ${PROJECT_SOURCE_DIR}/src/media/subtitle_pgs.cpp
    ${PROJECT_SOURCE_DIR}/src/media/subtitle_vobsub.cpp
    ${PROJECT_SOURCE_DIR}/src/media/byte_source.cpp
    ${PROJECT_SOURCE_DIR}/src/media/matroska_ebml.cpp
    ${PROJECT_SOURCE_DIR}/src/qt/scroll_gesture.cpp
    ${PROJECT_SOURCE_DIR}/src/qt/scroll_gesture.hpp
    ${PROJECT_SOURCE_DIR}/src/qt/player_core.cpp
    ${PROJECT_SOURCE_DIR}/src/qt/player_core_p.hpp
    ${PROJECT_SOURCE_DIR}/src/jobs.cpp
    ${PROJECT_SOURCE_DIR}/src/jobs.hpp
    ${PROJECT_SOURCE_DIR}/src/caption_service.cpp
    ${PROJECT_SOURCE_DIR}/src/caption_service.hpp)
  target_link_libraries(wam_mpv_video_item_native_host_test PRIVATE wam_caption_runtime wam_caption_prompt)
  target_include_directories(wam_mpv_video_item_native_host_test PRIVATE
    ${PROJECT_SOURCE_DIR}/src ${PROJECT_SOURCE_DIR}/src/qt)
  target_compile_features(wam_mpv_video_item_native_host_test PRIVATE
    cxx_std_20)
  target_compile_options(wam_mpv_video_item_native_host_test PRIVATE
    -Wall -Wextra -Wpedantic)
  target_link_libraries(wam_mpv_video_item_native_host_test PRIVATE
    wam_mpv_runtime
    wam_macos_native_qt_tracked
    Qt6::Core
    Qt6::Gui
    Qt6::Qml
    Qt6::Quick
    Qt6::OpenGL)
  set_target_properties(wam_mpv_video_item_native_host_test PROPERTIES
    AUTOMOC ON
    LINKER_LANGUAGE OBJCXX)
  add_test(NAME macos_mpv_video_item_native_host
    COMMAND wam_mpv_video_item_native_host_test)
  set_tests_properties(macos_mpv_video_item_native_host PROPERTIES
    TIMEOUT 20)

  if(WAM_ENABLE_MACOS_NATIVE_VIDEO)
    # Fixture-free gates with test-only declarations compile their complete
    # macro-bearing implementations privately. Production-layout contract
    # gates may link the production archive directly.
    add_executable(wam_avfoundation_media_source_test
      avfoundation_media_source_test.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_media_support.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_media_support.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_asset_context.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_asset_context.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_media_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_media_source.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_codec_capability.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_codec_capability.mm)
    target_include_directories(
      wam_avfoundation_media_source_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_compile_definitions(wam_avfoundation_media_source_test PRIVATE
      WAM_AVFOUNDATION_MEDIA_SOURCE_TESTING=1)
    target_link_libraries(wam_avfoundation_media_source_test PRIVATE
      wam_native_core
      "${WAM_COREFOUNDATION_FRAMEWORK}"
      "${WAM_COREGRAPHICS_FRAMEWORK}"
      "${WAM_COREMEDIA_FRAMEWORK}"
      "${WAM_COREVIDEO_FRAMEWORK}"
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
      "${WAM_AVFOUNDATION_FRAMEWORK}"
      "${WAM_VIDEOTOOLBOX_FRAMEWORK}")
    add_test(NAME macos_avfoundation_reader_cancellation
      COMMAND wam_avfoundation_media_source_test --cancel-only
        "${WAMKIT_TEST_FIXTURE_DIR}/av.mp4")
    set_tests_properties(macos_avfoundation_reader_cancellation PROPERTIES
      TIMEOUT 15 FIXTURES_REQUIRED wamkit_media)
    add_test(NAME macos_avfoundation_media_source
      COMMAND wam_avfoundation_media_source_test)
    set_tests_properties(macos_avfoundation_media_source PROPERTIES
      TIMEOUT 30)

    add_executable(wam_avfoundation_preview_source_test
      avfoundation_preview_source_test.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_media_support.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_media_support.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_codec_capability.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_codec_capability.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_asset_context.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_asset_context.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_preview_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_preview_source.mm)
    target_include_directories(
      wam_avfoundation_preview_source_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_compile_definitions(
      wam_avfoundation_preview_source_test PRIVATE
      WAM_AVFOUNDATION_PREVIEW_SOURCE_TESTING=1)
    target_link_libraries(wam_avfoundation_preview_source_test PRIVATE
      wam_native_core
      "${WAM_COREFOUNDATION_FRAMEWORK}"
      "${WAM_COREGRAPHICS_FRAMEWORK}"
      "${WAM_COREMEDIA_FRAMEWORK}"
      "${WAM_COREVIDEO_FRAMEWORK}"
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_AVFOUNDATION_FRAMEWORK}"
      "${WAM_VIDEOTOOLBOX_FRAMEWORK}")
    add_test(NAME macos_avfoundation_preview_source
      COMMAND wam_avfoundation_preview_source_test)
    set_tests_properties(macos_avfoundation_preview_source PROPERTIES
      TIMEOUT 30)

    add_executable(wam_native_apple_audio_probe native_apple_audio_probe.mm)
    target_link_libraries(wam_native_apple_audio_probe PRIVATE
      "${WAM_FOUNDATION_FRAMEWORK}" "${WAM_AUDIOTOOLBOX_FRAMEWORK}")

    add_executable(wam_native_apple_video_probe native_apple_video_probe.mm)
    target_link_libraries(wam_native_apple_video_probe PRIVATE
      wam_macos_native_backend "-framework ImageIO")

    add_executable(wam_native_coverage_source_probe
      native_coverage_source_probe.mm)
    target_link_libraries(wam_native_coverage_source_probe PRIVATE
      wam_macos_native_backend)

    add_executable(wam_native_coverage_audio_probe
      native_coverage_audio_probe.mm)
    target_link_libraries(wam_native_coverage_audio_probe PRIVATE
      wam_macos_native_backend)

    add_test(NAME native_coverage_wiring
      COMMAND "${Python3_EXECUTABLE}"
        "${PROJECT_SOURCE_DIR}/tests/native_coverage_wiring_test.py"
        --app "$<TARGET_FILE:wam>" --ffmpeg "${WAM_TEST_FFMPEG}")
    # Native menus need Cocoa; the harness itself guarantees parked,
    # muted, nonactivating windows even when the rest of ctest is offscreen.
    set_tests_properties(native_coverage_wiring PROPERTIES TIMEOUT 180
      ENVIRONMENT "QT_QPA_PLATFORM=cocoa")
    add_test(NAME macos_native_coverage_integration
      COMMAND "${Python3_EXECUTABLE}"
        "${PROJECT_SOURCE_DIR}/tests/native_coverage_integration.py"
        --audio "$<TARGET_FILE:wam_native_coverage_audio_probe>"
        --source "$<TARGET_FILE:wam_native_coverage_source_probe>"
        --ffmpeg "${WAM_TEST_FFMPEG}")
    set_tests_properties(macos_native_coverage_integration PROPERTIES TIMEOUT 90)
    add_test(NAME macos_native_phase0b_integration
      COMMAND "${Python3_EXECUTABLE}"
        "${PROJECT_SOURCE_DIR}/tests/native_phase0b_integration.py"
        --source "$<TARGET_FILE:wam_native_coverage_source_probe>"
        --video "$<TARGET_FILE:wam_native_apple_video_probe>"
        --ffmpeg "${WAM_TEST_FFMPEG}")
    set_tests_properties(macos_native_phase0b_integration PROPERTIES TIMEOUT 180 SKIP_RETURN_CODE 77)

    add_executable(wam_native_audio_converter_test
      native_audio_converter_test.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_audio_converter.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_audio_converter.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_audio_converter_backends.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_audio_converter_backends.mm)
    target_include_directories(wam_native_audio_converter_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_link_libraries(wam_native_audio_converter_test PRIVATE
      wam_native_core
      "${WAM_COREFOUNDATION_FRAMEWORK}"
      "${WAM_COREMEDIA_FRAMEWORK}"
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_AUDIOTOOLBOX_FRAMEWORK}")
    add_test(NAME macos_native_audio_converter
      COMMAND wam_native_audio_converter_test)
    set_tests_properties(macos_native_audio_converter PROPERTIES
      TIMEOUT 20)

    # The audio session test builds its own strict-flag translation units in
    # a temporary directory rather than linking a CMake target, which is why
    # it is a script. Registering the script is what puts it in ctest; it
    # needs no target of its own and stays runnable by hand.
    add_test(NAME macos_native_audio_session
      COMMAND sh
      "${PROJECT_SOURCE_DIR}/tests/run_native_audio_session_test.sh")
    set_tests_properties(macos_native_audio_session PROPERTIES
      TIMEOUT 600)

    # New Opus behaviour lives alongside the frozen converter contract
    # rather than inside it.
    add_executable(wam_native_audio_converter_opus_test
      native_audio_converter_opus_test.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_audio_converter.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_audio_converter.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_audio_converter_backends.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_audio_converter_backends.mm)
    target_include_directories(wam_native_audio_converter_opus_test
      PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_link_libraries(wam_native_audio_converter_opus_test PRIVATE
      wam_native_core
      "${WAM_COREFOUNDATION_FRAMEWORK}"
      "${WAM_COREMEDIA_FRAMEWORK}"
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_AUDIOTOOLBOX_FRAMEWORK}")
    add_test(NAME macos_native_audio_converter_opus
      COMMAND wam_native_audio_converter_opus_test)
    set_tests_properties(macos_native_audio_converter_opus PROPERTIES
      TIMEOUT 20)

    add_executable(wam_native_audio_channel_map_test
      native_audio_channel_map_test.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_audio_channel_map.hpp)
    target_include_directories(wam_native_audio_channel_map_test
      PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_link_libraries(wam_native_audio_channel_map_test PRIVATE
      wam_native_core
      "${WAM_COREFOUNDATION_FRAMEWORK}"
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
      "${WAM_COREAUDIO_FRAMEWORK}")
    add_test(NAME macos_native_audio_channel_map
      COMMAND wam_native_audio_channel_map_test)
    set_tests_properties(macos_native_audio_channel_map PROPERTIES
      TIMEOUT 20)

    add_executable(wam_native_audio_stretch_stage_test
      native_audio_stretch_stage_test.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_audio_stretch_stage.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_audio_stretch_stage.mm)
    target_include_directories(wam_native_audio_stretch_stage_test
      PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_link_libraries(wam_native_audio_stretch_stage_test PRIVATE
      wam_native_core
      "${WAM_COREMEDIA_FRAMEWORK}"
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
      "${WAM_COREAUDIO_FRAMEWORK}")
    add_test(NAME macos_native_audio_stretch_stage
      COMMAND wam_native_audio_stretch_stage_test)
    set_tests_properties(macos_native_audio_stretch_stage PROPERTIES
      TIMEOUT 60)

    add_executable(wam_native_audio_output_converter_test
      native_audio_output_converter_test.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_audio_sample_rates.hpp)
    target_include_directories(wam_native_audio_output_converter_test
      PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_link_libraries(wam_native_audio_output_converter_test PRIVATE
      wam_native_core
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
      "${WAM_COREAUDIO_FRAMEWORK}")
    add_test(NAME macos_native_audio_output_converter
      COMMAND wam_native_audio_output_converter_test)
    set_tests_properties(macos_native_audio_output_converter PROPERTIES
      TIMEOUT 120)

    add_executable(wam_native_audio_output_test
      native_audio_output_test.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_audio_output.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_audio_output.mm
      ${PROJECT_SOURCE_DIR}/src/media/native_audio_render_core.cpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_audio_stretch_stage.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_audio_stretch_stage.mm)
    target_include_directories(wam_native_audio_output_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_compile_definitions(wam_native_audio_output_test PRIVATE
      WAM_NATIVE_TEST_SEAMS=1)
    target_link_libraries(wam_native_audio_output_test PRIVATE
      wam_native_core
      "${WAM_COREMEDIA_FRAMEWORK}"
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
      "${WAM_COREAUDIO_FRAMEWORK}")
    add_test(NAME macos_native_audio_output
      COMMAND wam_native_audio_output_test)
    set_tests_properties(macos_native_audio_output PROPERTIES TIMEOUT 30)

    add_executable(wam_native_surface_budget_test
      native_surface_budget_test.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_surface_budget.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_surface_budget.mm)
    target_include_directories(wam_native_surface_budget_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_compile_definitions(wam_native_surface_budget_test PRIVATE
      WAM_NATIVE_SURFACE_BUDGET_TESTING=1)
    target_link_libraries(wam_native_surface_budget_test PRIVATE
      "${WAM_COREFOUNDATION_FRAMEWORK}"
      "${WAM_COREVIDEO_FRAMEWORK}"
      "${WAM_IOSURFACE_FRAMEWORK}")
    add_test(NAME macos_native_surface_budget
      COMMAND wam_native_surface_budget_test)
    set_tests_properties(macos_native_surface_budget PROPERTIES TIMEOUT 20)

    # The multi-window resource envelope: one cap, every derived bound.
    # Deliberately a separate target from the budget suite above so the
    # derived constants are checked from a translation unit that does not
    # derive them.
    add_executable(wam_native_concurrency_limits_test
      native_concurrency_limits_test.cpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_concurrency_limits.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_layer_presentation_state.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_surface_budget.hpp)
    target_include_directories(wam_native_concurrency_limits_test
      PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_link_libraries(wam_native_concurrency_limits_test PRIVATE
      "${WAM_COREVIDEO_FRAMEWORK}")
    add_test(NAME macos_native_concurrency_limits
      COMMAND wam_native_concurrency_limits_test)
    set_tests_properties(macos_native_concurrency_limits
      PROPERTIES TIMEOUT 20)

    # The libvpx VP8 decode stage: bounded pool, I420 -> NV12 conversion,
    # stage lifecycle, and the once-per-open lane selection. Fixture-free --
    # the decode arm encodes its own VP8 stream with libvpx.
    if(WAM_ENABLE_SOFTWARE_VP8)
      add_executable(wam_software_vp8_test
        software_vp8_test.mm
        ${PROJECT_SOURCE_DIR}/src/platform/macos/software_vp8_decoder.hpp
        ${PROJECT_SOURCE_DIR}/src/platform/macos/software_vp8_decoder.mm
        ${PROJECT_SOURCE_DIR}/src/platform/macos/software_presentation_pool.mm
        ${PROJECT_SOURCE_DIR}/src/platform/macos/video_decode_lane.hpp
        ${PROJECT_SOURCE_DIR}/src/platform/macos/native_surface_budget.hpp
        ${PROJECT_SOURCE_DIR}/src/platform/macos/native_surface_budget.mm
        ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_presenter.hpp
        ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_presenter.mm
        ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_codec_capability.hpp
        ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_codec_capability.mm
        ${PROJECT_SOURCE_DIR}/src/platform/macos/video_toolbox_decoder.hpp
        ${PROJECT_SOURCE_DIR}/src/platform/macos/video_toolbox_decoder.mm)
      target_include_directories(wam_software_vp8_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
      target_compile_definitions(wam_software_vp8_test PRIVATE
        WAM_ENABLE_SOFTWARE_VP8)
      target_link_libraries(wam_software_vp8_test PRIVATE
        wam_native_core
        PkgConfig::WAM_LIBVPX
        "${WAM_COREFOUNDATION_FRAMEWORK}"
        "${WAM_COREMEDIA_FRAMEWORK}"
        "${WAM_COREVIDEO_FRAMEWORK}"
        "${WAM_FOUNDATION_FRAMEWORK}"
        "${WAM_IOSURFACE_FRAMEWORK}"
        "${WAM_VIDEOTOOLBOX_FRAMEWORK}")
      target_compile_options(wam_software_vp8_test PRIVATE
        "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
        -Wall -Wextra -Wpedantic)
      set_target_properties(wam_software_vp8_test PROPERTIES
        LINKER_LANGUAGE OBJCXX)
      add_test(NAME macos_software_vp8 COMMAND wam_software_vp8_test)
      set_tests_properties(macos_software_vp8 PROPERTIES TIMEOUT 60)
    endif()

    add_executable(wam_native_video_consumer_test
      native_video_consumer_test.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_consumer.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_consumer.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_surface_budget.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_surface_budget.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_codec_capability.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_codec_capability.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_presenter.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_presenter.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/video_toolbox_decoder.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/video_toolbox_decoder.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/software_vp8_decoder.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/software_vp8_decoder.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/software_presentation_pool.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/video_decode_lane.hpp)
    target_include_directories(wam_native_video_consumer_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_compile_definitions(wam_native_video_consumer_test PRIVATE
      WAM_NATIVE_VIDEO_CONSUMER_TESTING=1)
    if(WAM_ENABLE_SOFTWARE_VP8)
      target_link_libraries(wam_native_video_consumer_test PRIVATE
        PkgConfig::WAM_LIBVPX)
    endif()
    target_link_libraries(wam_native_video_consumer_test PRIVATE
      wam_native_core
      "${WAM_COREFOUNDATION_FRAMEWORK}"
      "${WAM_COREMEDIA_FRAMEWORK}"
      "${WAM_COREVIDEO_FRAMEWORK}"
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_IOSURFACE_FRAMEWORK}"
      "${WAM_METAL_FRAMEWORK}"
      "${WAM_VIDEOTOOLBOX_FRAMEWORK}")
    add_test(NAME macos_native_video_consumer
      COMMAND wam_native_video_consumer_test)
    set_tests_properties(macos_native_video_consumer PROPERTIES TIMEOUT 30)

    # Layer-presentation contract gate. The presenter is headless by
    # construction -- createTracked(nullptr, ...) builds its own detached
    # AVSampleBufferDisplayLayer, which accepts and acknowledges enqueues
    # without ever joining a view hierarchy -- so it compiles here beside the
    # other fixture-free native gates rather than in the Qt window block.
    # Only the presenter itself is compiled in; FrameLease and the surface
    # budget come from the one production video core.
    # native_layer_host_view.mm comes along because the output's
    # setPresentationRotation defers the actual CoreAnimation work to it --
    # the rotation lives with the layer's geometry, not with the enqueue
    # path. AppKit and CoreImage are its dependencies, not the output's.
    add_executable(wam_native_layer_video_output_test
      native_layer_video_output_test.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_layer_video_output.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_layer_video_output.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_layer_host_view.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_layer_host_view.mm)
    target_include_directories(
      wam_native_layer_video_output_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_compile_definitions(wam_native_layer_video_output_test PRIVATE
      WAM_NATIVE_LAYER_VIDEO_TESTING=1)
    target_link_libraries(wam_native_layer_video_output_test PRIVATE
      wam_native_core
      wam_macos_native_video_core
      "${WAM_COREFOUNDATION_FRAMEWORK}"
      "${WAM_COREMEDIA_FRAMEWORK}"
      "${WAM_COREVIDEO_FRAMEWORK}"
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_IOSURFACE_FRAMEWORK}"
      "${WAM_AVFOUNDATION_FRAMEWORK}"
      "${WAM_APPKIT_FRAMEWORK}"
      "${WAM_COREIMAGE_FRAMEWORK}"
      "${WAM_QUARTZCORE_FRAMEWORK}")
    add_test(NAME macos_native_layer_video_output
      COMMAND wam_native_layer_video_output_test)
    set_tests_properties(macos_native_layer_video_output PROPERTIES
      TIMEOUT 30
      SKIP_RETURN_CODE 77)

    # The arbiter has no test-only class layout. Exercise the single
    # production implementation through the backend archive instead of
    # compiling a second copy into this executable.
    add_executable(wam_native_tracked_video_arbiter_test
      native_tracked_video_arbiter_test.mm)
    target_include_directories(
      wam_native_tracked_video_arbiter_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_link_libraries(wam_native_tracked_video_arbiter_test PRIVATE
      wam_macos_native_backend)
    add_test(NAME macos_native_tracked_video_arbiter
      COMMAND wam_native_tracked_video_arbiter_test)
    set_tests_properties(macos_native_tracked_video_arbiter PROPERTIES
      TIMEOUT 20)

    # The Matroska preview source's own contract. It links the main
    # Matroska media source as well, so the promoted sample builders in
    # matroska_sample_builder.hpp are proved to serve both consumers from
    # one definition rather than two copies.
    add_executable(wam_matroska_preview_source_test
      matroska_preview_source_test.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_asset_context.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_asset_context.cpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_media_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_media_source.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_preview_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_preview_source.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/core_media_carriage.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/core_media_carriage.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_sample_builder.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_sample_builder.mm
      # native_preview_source.mm switches exhaustively on backendKind, so
      # every backend's preview implementation is part of this test's link
      # closure whether or not the test exercises it.
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_asset_context.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_asset_context.cpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_media_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_media_source.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_preview_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_preview_source.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_sample_builder.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_sample_builder.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_media_support.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_media_support.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_codec_capability.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_codec_capability.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_asset_context.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_asset_context.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_preview_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_preview_source.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_preview_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_preview_source.mm)
    target_include_directories(
      wam_matroska_preview_source_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_link_libraries(wam_matroska_preview_source_test PRIVATE
      wam_native_core
      wam_macos_native_video_core
      "${WAM_COREMEDIA_FRAMEWORK}"
      "${WAM_COREFOUNDATION_FRAMEWORK}"
      "${WAM_COREGRAPHICS_FRAMEWORK}"
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
      "${WAM_AVFOUNDATION_FRAMEWORK}"
      "${WAM_VIDEOTOOLBOX_FRAMEWORK}")
    add_test(NAME macos_matroska_preview_source
      COMMAND wam_matroska_preview_source_test)
    set_tests_properties(macos_matroska_preview_source PROPERTIES
      TIMEOUT 20)

    # The two custom-container media sources and the MPEG-TS preview source,
    # driven over their neutral public surface against containers muxed at
    # test time.

    add_executable(wam_matroska_media_source_test
      matroska_media_source_test.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_asset_context.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_asset_context.cpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_media_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_media_source.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/core_media_carriage.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/core_media_carriage.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_sample_builder.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_sample_builder.mm)
    target_include_directories(
      wam_matroska_media_source_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_link_libraries(wam_matroska_media_source_test PRIVATE
      wam_native_core
      wam_macos_native_video_core
      "${WAM_COREMEDIA_FRAMEWORK}"
      "${WAM_COREFOUNDATION_FRAMEWORK}"
      "${WAM_COREGRAPHICS_FRAMEWORK}"
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
      "${WAM_AVFOUNDATION_FRAMEWORK}")
    add_test(NAME macos_matroska_media_source
      COMMAND wam_matroska_media_source_test "${WAM_TEST_FFMPEG}")
    set_tests_properties(macos_matroska_media_source PROPERTIES
      TIMEOUT 120
      SKIP_RETURN_CODE 77)

    add_executable(wam_mpegts_media_source_test
      mpegts_media_source_test.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_asset_context.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_asset_context.cpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_media_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_media_source.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/core_media_carriage.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/core_media_carriage.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_sample_builder.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_sample_builder.mm)
    target_include_directories(
      wam_mpegts_media_source_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_link_libraries(wam_mpegts_media_source_test PRIVATE
      wam_native_core
      wam_macos_native_video_core
      "${WAM_COREMEDIA_FRAMEWORK}"
      "${WAM_COREFOUNDATION_FRAMEWORK}"
      "${WAM_COREGRAPHICS_FRAMEWORK}"
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
      "${WAM_AVFOUNDATION_FRAMEWORK}")
    add_test(NAME macos_mpegts_media_source
      COMMAND wam_mpegts_media_source_test "${WAM_MPEGTS_FIXTURE_DIR}")
    set_tests_properties(macos_mpegts_media_source PROPERTIES
      TIMEOUT 120
      FIXTURES_REQUIRED mpegts_corpus)

    add_executable(wam_mpegts_preview_source_test
      mpegts_preview_source_test.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_asset_context.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_asset_context.cpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_media_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_media_source.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_preview_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_preview_source.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_sample_builder.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_sample_builder.mm
      # native_preview_source.mm switches exhaustively on backendKind, so
      # every backend's preview implementation is part of this test's link
      # closure whether or not the test exercises it.
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_asset_context.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_asset_context.cpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_media_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_media_source.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_preview_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_preview_source.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/core_media_carriage.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/core_media_carriage.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_sample_builder.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_sample_builder.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_media_support.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_media_support.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_codec_capability.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_codec_capability.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_asset_context.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_asset_context.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_preview_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_preview_source.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_preview_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_preview_source.mm)
    target_include_directories(
      wam_mpegts_preview_source_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_link_libraries(wam_mpegts_preview_source_test PRIVATE
      wam_native_core
      wam_macos_native_video_core
      "${WAM_COREMEDIA_FRAMEWORK}"
      "${WAM_COREFOUNDATION_FRAMEWORK}"
      "${WAM_COREGRAPHICS_FRAMEWORK}"
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
      "${WAM_AVFOUNDATION_FRAMEWORK}"
      "${WAM_VIDEOTOOLBOX_FRAMEWORK}")
    add_test(NAME macos_mpegts_preview_source
      COMMAND wam_mpegts_preview_source_test "${WAM_TEST_FFMPEG}")
    set_tests_properties(macos_mpegts_preview_source PROPERTIES
      TIMEOUT 120
      SKIP_RETURN_CODE 77)

    # The Traits seam of the shared custom-source core: both backends are
    # linked so the two Traits can be compared in one binary.
    add_executable(wam_native_custom_source_traits_test
      native_custom_source_traits_test.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_custom_source_core.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_asset_context.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_asset_context.cpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_media_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_media_source.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/core_media_carriage.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/core_media_carriage.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_sample_builder.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_sample_builder.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_asset_context.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_asset_context.cpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_media_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_media_source.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_sample_builder.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_sample_builder.mm)
    target_include_directories(
      wam_native_custom_source_traits_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_link_libraries(wam_native_custom_source_traits_test PRIVATE
      wam_native_core
      wam_macos_native_video_core
      "${WAM_COREMEDIA_FRAMEWORK}"
      "${WAM_COREFOUNDATION_FRAMEWORK}"
      "${WAM_COREGRAPHICS_FRAMEWORK}"
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
      "${WAM_AVFOUNDATION_FRAMEWORK}")
    add_test(NAME macos_native_custom_source_traits
      COMMAND wam_native_custom_source_traits_test)
    set_tests_properties(macos_native_custom_source_traits PROPERTIES
      TIMEOUT 30)

    # The lane's deterministic synthetic-frame seam is absent from the
    # shipping class. Compile the lane and its source dependency privately
    # under one macro, while reusing the production decoder/video core.
    add_executable(wam_native_preview_frame_lane_test
      native_preview_frame_lane_test.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_media_support.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_media_support.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_codec_capability.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_codec_capability.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_asset_context.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_asset_context.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_preview_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_preview_source.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_preview_frame_lane.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_preview_frame_lane.mm)
    target_include_directories(
      wam_native_preview_frame_lane_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_compile_definitions(
      wam_native_preview_frame_lane_test PRIVATE
      WAM_NATIVE_PREVIEW_FRAME_LANE_TESTING=1)
    target_link_libraries(wam_native_preview_frame_lane_test PRIVATE
      wam_native_core
      wam_macos_native_video_core
      "${WAM_COREGRAPHICS_FRAMEWORK}"
      "${WAM_AVFOUNDATION_FRAMEWORK}"
      "${WAM_VIDEOTOOLBOX_FRAMEWORK}")
    add_test(NAME macos_native_preview_frame_lane
      COMMAND wam_native_preview_frame_lane_test)
    set_tests_properties(macos_native_preview_frame_lane PROPERTIES
      TIMEOUT 30)

    # Every implementation in this private closure sees the session test
    # seam, and no production archive containing a differently laid-out
    # NativeMediaSession is linked.
    add_executable(wam_native_media_session_test
      native_media_session_test.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_media_source.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_media_source.mm
      ${PROJECT_SOURCE_DIR}/src/media/native_media_source.hpp
      ${PROJECT_SOURCE_DIR}/src/media/native_media_source.cpp
      ${PROJECT_SOURCE_DIR}/src/media/native_media_dispatcher.hpp
      ${PROJECT_SOURCE_DIR}/src/media/native_media_dispatcher.cpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_media_support.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_media_support.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_codec_capability.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_codec_capability.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_asset_context.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_asset_context.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_preview_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/avfoundation_preview_source.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_asset_context.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_asset_context.cpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_preview_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_preview_source.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/core_media_carriage.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/core_media_carriage.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_sample_builder.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/matroska_sample_builder.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_asset_context.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_asset_context.cpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_preview_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_preview_source.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_sample_builder.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/mpegts_sample_builder.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_preview_source.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_preview_source.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_media_session.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_media_session.mm
      ${PROJECT_SOURCE_DIR}/src/media/native_media_clock.hpp
      ${PROJECT_SOURCE_DIR}/src/media/native_media_clock.cpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_silent_timebase.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_silent_timebase.cpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_preview_frame_lane.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_preview_frame_lane.mm)
    target_include_directories(wam_native_media_session_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_compile_definitions(wam_native_media_session_test PRIVATE
      WAM_AVFOUNDATION_ASSET_CONTEXT_TESTING=1
      WAM_NATIVE_MEDIA_SESSION_TESTING=1)
    target_link_libraries(wam_native_media_session_test PRIVATE
      wam_native_core
      wam_macos_native_video_core
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_COREMEDIA_FRAMEWORK}"
      "${WAM_COREAUDIO_FRAMEWORK}"
      "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
      "${WAM_COREGRAPHICS_FRAMEWORK}"
      "${WAM_AVFOUNDATION_FRAMEWORK}"
      "${WAM_VIDEOTOOLBOX_FRAMEWORK}")
    add_test(NAME macos_native_media_session
      COMMAND wam_native_media_session_test)
    add_test(NAME macos_mpegts_session_fallback
      COMMAND wam_native_media_session_test --mpegts-integration)
    set_tests_properties(macos_mpegts_session_fallback PROPERTIES
      FIXTURES_REQUIRED mpegts_corpus
      ENVIRONMENT "WAM_MPEGTS_FIXTURES=${WAM_MPEGTS_FIXTURE_DIR}")
    set_tests_properties(macos_native_media_session PROPERTIES TIMEOUT 30)

    # Pure route/retirement contract gate. It intentionally links the one
    # production backend archive for exact-position preflight instead of
    # compiling a second NativeMediaSession or NativePlaybackOwner.
    add_executable(wam_native_playback_owner_contract_test
      native_playback_owner_contract_test.cpp)
    target_include_directories(
      wam_native_playback_owner_contract_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_link_libraries(wam_native_playback_owner_contract_test PRIVATE
      wam_macos_native_backend)
    add_test(NAME macos_native_playback_owner_contract
      COMMAND wam_native_playback_owner_contract_test)
    set_tests_properties(macos_native_playback_owner_contract PROPERTIES
      TIMEOUT 10)

    add_executable(wam_native_open_preflight_test
      native_open_preflight_test.mm
      ${PROJECT_SOURCE_DIR}/src/qt/native_open_preflight.hpp
      ${PROJECT_SOURCE_DIR}/src/qt/native_open_preflight.mm)
    target_include_directories(wam_native_open_preflight_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_link_libraries(wam_native_open_preflight_test PRIVATE
      wam_macos_native_session_system
      Qt6::Core)
    add_test(NAME macos_native_open_preflight
      COMMAND wam_native_open_preflight_test)
    set_tests_properties(macos_native_open_preflight PROPERTIES TIMEOUT 10)

    add_executable(wam_native_benchmark_telemetry_test
      native_benchmark_telemetry_test.cpp
      ${PROJECT_SOURCE_DIR}/src/qt/native_benchmark_telemetry.hpp
      ${PROJECT_SOURCE_DIR}/src/qt/native_benchmark_telemetry.cpp)
    target_include_directories(
      wam_native_benchmark_telemetry_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_compile_features(
      wam_native_benchmark_telemetry_test PRIVATE cxx_std_20)
    target_compile_options(
      wam_native_benchmark_telemetry_test PRIVATE
      -Wall -Wextra -Wpedantic)
    add_test(NAME macos_native_benchmark_telemetry
      COMMAND wam_native_benchmark_telemetry_test)
    set_tests_properties(macos_native_benchmark_telemetry PROPERTIES
      TIMEOUT 10)

    foreach(WAM_HEADLESS_NATIVE_TEST_TARGET IN ITEMS
        wam_avfoundation_media_source_test
        wam_avfoundation_preview_source_test
        wam_matroska_preview_source_test
        wam_matroska_media_source_test
        wam_mpegts_media_source_test
        wam_mpegts_preview_source_test
        wam_native_custom_source_traits_test
        wam_native_audio_converter_test
        wam_native_audio_output_test
        wam_native_audio_output_converter_test
        wam_native_audio_stretch_stage_test
        wam_native_surface_budget_test
        wam_native_video_consumer_test
        wam_native_layer_video_output_test
        wam_native_tracked_video_arbiter_test
        wam_native_preview_frame_lane_test
        wam_native_media_session_test
        wam_native_playback_owner_contract_test
        wam_native_open_preflight_test)
      target_compile_features(${WAM_HEADLESS_NATIVE_TEST_TARGET} PRIVATE
        cxx_std_20)
      target_compile_options(${WAM_HEADLESS_NATIVE_TEST_TARGET} PRIVATE
        "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
        -Wall -Wextra -Wpedantic)
      set_target_properties(${WAM_HEADLESS_NATIVE_TEST_TARGET} PROPERTIES
        LINKER_LANGUAGE OBJCXX)
    endforeach()

    add_executable(wam_native_video_test
      native_video_presenter_test.mm
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_presenter.hpp
      ${PROJECT_SOURCE_DIR}/src/platform/macos/native_video_presenter.mm
      ${WAM_MACOS_NATIVE_VIDEO_METAL_MAPPER_SOURCES})
    target_include_directories(wam_native_video_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_compile_definitions(wam_native_video_test PRIVATE
      WAM_NATIVE_FRAME_LEASE_TESTING=1
      WAM_NATIVE_SURFACE_BUDGET_TESTING=1)
    target_link_libraries(wam_native_video_test PRIVATE
      "${WAM_COREFOUNDATION_FRAMEWORK}"
      "${WAM_COREMEDIA_FRAMEWORK}"
      "${WAM_COREVIDEO_FRAMEWORK}"
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_IOSURFACE_FRAMEWORK}"
      "${WAM_APPKIT_FRAMEWORK}"
      "${WAM_METAL_FRAMEWORK}"
      "${WAM_QUARTZCORE_FRAMEWORK}")
    target_compile_options(wam_native_video_test PRIVATE
      "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
      -Wall -Wextra -Wpedantic)
    set_target_properties(wam_native_video_test PROPERTIES
      LINKER_LANGUAGE OBJCXX)
    add_test(NAME macos_native_video COMMAND wam_native_video_test)
    set_tests_properties(macos_native_video PROPERTIES SKIP_RETURN_CODE 77)

    # OpenGL/CGL hardware gate matching the shipping Qt graphics backend.
    # The item is absent from default application builds; the opt-in
    # production seam compiles it but does not register or construct it.
    add_executable(wam_native_qt_gl_compositor_test
      native_qt_gl_compositor_test.mm
      ${PROJECT_SOURCE_DIR}/src/qt/macos/qt_gl_video_item.hpp
      ${PROJECT_SOURCE_DIR}/src/qt/macos/qt_gl_video_item.mm)
    target_include_directories(wam_native_qt_gl_compositor_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_compile_definitions(wam_native_qt_gl_compositor_test PRIVATE
      WAM_NATIVE_GL_VIDEO_TESTING=1
      GL_SILENCE_DEPRECATION=1)
    target_link_libraries(wam_native_qt_gl_compositor_test PRIVATE
      wam_macos_native_video_core
      Qt6::Core
      Qt6::Gui
      Qt6::Qml
      Qt6::Quick
      "${WAM_OPENGL_FRAMEWORK}")
    target_compile_options(wam_native_qt_gl_compositor_test PRIVATE
      "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
      -Wall -Wextra -Wpedantic)
    set_target_properties(wam_native_qt_gl_compositor_test PROPERTIES
      AUTOMOC ON
      LINKER_LANGUAGE OBJCXX)
    add_test(NAME macos_native_qt_gl_compositor
      COMMAND wam_native_qt_gl_compositor_test)
    set_tests_properties(macos_native_qt_gl_compositor PROPERTIES
      TIMEOUT 120 SKIP_RETURN_CODE 77)

    # Scene-graph route adapter gate (WAM_PRESENTATION=scenegraph). The
    # adapter's fault-injection seams exist only under the testing macro, so
    # the test compiles the adapter and item privately instead of linking
    # the production archive.
    add_executable(wam_native_qt_gl_output_test
      native_qt_gl_output_test.mm
      ${PROJECT_SOURCE_DIR}/src/qt/macos/native_qt_gl_output.hpp
      ${PROJECT_SOURCE_DIR}/src/qt/macos/native_qt_gl_output.mm
      ${PROJECT_SOURCE_DIR}/src/qt/macos/qt_gl_video_item.hpp
      ${PROJECT_SOURCE_DIR}/src/qt/macos/qt_gl_video_item.mm)
    target_include_directories(wam_native_qt_gl_output_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_compile_definitions(wam_native_qt_gl_output_test PRIVATE
      WAM_NATIVE_GL_VIDEO_TESTING=1
      GL_SILENCE_DEPRECATION=1)
    target_link_libraries(wam_native_qt_gl_output_test PRIVATE
      wam_macos_native_video_core
      Qt6::Core
      Qt6::Gui
      Qt6::Qml
      Qt6::Quick
      "${WAM_OPENGL_FRAMEWORK}")
    target_compile_options(wam_native_qt_gl_output_test PRIVATE
      "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
      -Wall -Wextra -Wpedantic)
    set_target_properties(wam_native_qt_gl_output_test PROPERTIES
      AUTOMOC ON
      LINKER_LANGUAGE OBJCXX)
    add_test(NAME macos_native_qt_gl_output
      COMMAND wam_native_qt_gl_output_test)
    set_tests_properties(macos_native_qt_gl_output PROPERTIES TIMEOUT 120 SKIP_RETURN_CODE 77)

    add_executable(wam_video_toolbox_decoder_test
      video_toolbox_decoder_test.mm
      ${WAM_MACOS_NATIVE_VIDEO_CORE_SOURCES}
      ${WAM_MACOS_NATIVE_VIDEO_METAL_MAPPER_SOURCES})
    target_include_directories(wam_video_toolbox_decoder_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_compile_definitions(wam_video_toolbox_decoder_test PRIVATE
      WAM_NATIVE_VIDEO_TESTING=1
      GL_SILENCE_DEPRECATION=1)
    if(WAM_ENABLE_SOFTWARE_VP8)
      # This target compiles the core sources directly rather than linking
      # the library, so it needs the same feature definition and the same
      # libvpx link the library carries.
      target_compile_definitions(wam_video_toolbox_decoder_test PRIVATE
        WAM_ENABLE_SOFTWARE_VP8)
      target_link_libraries(wam_video_toolbox_decoder_test PRIVATE
        PkgConfig::WAM_LIBVPX)
    endif()
    target_link_libraries(wam_video_toolbox_decoder_test PRIVATE
      wam_native_core
      "${WAM_COREFOUNDATION_FRAMEWORK}"
      "${WAM_COREMEDIA_FRAMEWORK}"
      "${WAM_COREVIDEO_FRAMEWORK}"
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_IOSURFACE_FRAMEWORK}"
      "${WAM_METAL_FRAMEWORK}"
      "${WAM_OPENGL_FRAMEWORK}"
      "${WAM_VIDEOTOOLBOX_FRAMEWORK}"
      "${WAM_AVFOUNDATION_FRAMEWORK}")
    target_compile_options(wam_video_toolbox_decoder_test PRIVATE
      "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
      -Wall -Wextra -Wpedantic)
    set_target_properties(wam_video_toolbox_decoder_test PROPERTIES
      LINKER_LANGUAGE OBJCXX)
    add_test(NAME macos_video_toolbox_decoder_limits
      COMMAND wam_video_toolbox_decoder_test --limits-only)
    set_tests_properties(macos_video_toolbox_decoder_limits PROPERTIES
      TIMEOUT 10)
    set(WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE
      "${WAM_NATIVE_VIDEO_TEST_FIXTURE}")
    set(WAM_RESOLVED_NATIVE_VIDEO_10BIT_TEST_FIXTURE
      "${WAM_NATIVE_VIDEO_10BIT_TEST_FIXTURE}")
    if(NOT WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE AND
        EXISTS "${PROJECT_SOURCE_DIR}/test-media/sample-h264.mp4")
      set(WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE
        "${PROJECT_SOURCE_DIR}/test-media/sample-h264.mp4")
    endif()

    if(WAM_REQUIRE_NATIVE_VIDEO_TEST_HARDWARE)
      if(NOT WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE OR
          NOT EXISTS "${WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE}")
        message(FATAL_ERROR
          "WAM_REQUIRE_NATIVE_VIDEO_TEST_HARDWARE requires an existing "
          "H.264 fixture")
      endif()
      if(NOT WAM_RESOLVED_NATIVE_VIDEO_10BIT_TEST_FIXTURE OR
          NOT EXISTS "${WAM_RESOLVED_NATIVE_VIDEO_10BIT_TEST_FIXTURE}")
        message(FATAL_ERROR
          "WAM_REQUIRE_NATIVE_VIDEO_TEST_HARDWARE requires an existing "
          "Main 10 HEVC fixture")
      endif()
    endif()

    set(WAM_NATIVE_HEADLESS_PERFORMANCE_FIXTURE
      "${PROJECT_SOURCE_DIR}/test-media/sample-h264.mp4")
    # Always compile the production-layout regression, including in clean
    # checkouts without media. Only its real-file execution needs the known
    # H.264/AAC fixture. Verdicts use identity, reuse, and bounded-ownership
    # facts; optional timings remain report-only.
    add_executable(wam_native_headless_performance_test
      native_headless_performance_test.mm)
    target_include_directories(
      wam_native_headless_performance_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
    target_compile_features(
      wam_native_headless_performance_test PRIVATE cxx_std_20)
    target_compile_options(
      wam_native_headless_performance_test PRIVATE
      "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
      -Wall -Wextra -Wpedantic)
    target_link_libraries(wam_native_headless_performance_test PRIVATE
      wam_macos_native_backend)
    set_target_properties(
      wam_native_headless_performance_test PROPERTIES
      LINKER_LANGUAGE OBJCXX)
    if(EXISTS "${WAM_NATIVE_HEADLESS_PERFORMANCE_FIXTURE}")
      add_test(NAME macos_native_headless_performance
        COMMAND wam_native_headless_performance_test
          "${WAM_NATIVE_HEADLESS_PERFORMANCE_FIXTURE}")
      set_tests_properties(macos_native_headless_performance PROPERTIES
        TIMEOUT 30)
    endif()

    if(WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE AND
        EXISTS "${WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE}")
      set(WAM_VIDEO_TOOLBOX_DECODER_TEST_ARGUMENTS
        "${WAM_RESOLVED_NATIVE_VIDEO_TEST_FIXTURE}")
      if(WAM_RESOLVED_NATIVE_VIDEO_10BIT_TEST_FIXTURE AND
          EXISTS "${WAM_RESOLVED_NATIVE_VIDEO_10BIT_TEST_FIXTURE}")
        list(APPEND WAM_VIDEO_TOOLBOX_DECODER_TEST_ARGUMENTS
          "${WAM_RESOLVED_NATIVE_VIDEO_10BIT_TEST_FIXTURE}")
      else()
        message(WARNING
          "Native VideoToolbox decoder test will run without real P010 "
          "decode coverage; set WAM_NATIVE_VIDEO_10BIT_TEST_FIXTURE to "
          "enable it")
      endif()
      if(WAM_REQUIRE_NATIVE_VIDEO_TEST_HARDWARE)
        list(APPEND WAM_VIDEO_TOOLBOX_DECODER_TEST_ARGUMENTS
          "--require-hardware")
      endif()
      add_test(NAME macos_video_toolbox_decoder
        COMMAND wam_video_toolbox_decoder_test
          ${WAM_VIDEO_TOOLBOX_DECODER_TEST_ARGUMENTS})
      set_tests_properties(macos_video_toolbox_decoder PROPERTIES
        TIMEOUT 30)
    else()
      message(WARNING
        "Fixture-backed native video tests were not registered; set "
        "WAM_NATIVE_VIDEO_TEST_FIXTURE to enable them")
    endif()
  endif()
endif()

add_executable(wam_software_audio_packet_test software_audio_packet_test.cpp)
target_include_directories(wam_software_audio_packet_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
add_test(NAME software_audio_packet COMMAND wam_software_audio_packet_test)

add_executable(wam_software_color_qualification_test software_color_qualification_test.cpp)
target_include_directories(wam_software_color_qualification_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
add_test(NAME software_color_qualification COMMAND wam_software_color_qualification_test)

add_executable(wam_native_late_frame_trace_test native_late_frame_trace_test.cpp)
target_include_directories(wam_native_late_frame_trace_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
add_test(NAME native_late_frame_trace COMMAND wam_native_late_frame_trace_test)
if(WAM_NATIVE_BENCHMARK_TELEMETRY AND TARGET wam_native_video_consumer_test)
  set_tests_properties(macos_native_video_consumer PROPERTIES
    ENVIRONMENT "WAM_NATIVE_BENCHMARK_TELEMETRY=1")
endif()

add_executable(wam_mpv_frame_counters_test mpv_frame_counters_test.cpp)
target_include_directories(wam_mpv_frame_counters_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
target_link_libraries(wam_mpv_frame_counters_test PRIVATE wam_mpv_headers)
add_test(NAME mpv_frame_counters COMMAND wam_mpv_frame_counters_test)

if(APPLE)
  add_test(NAME native_stage_defaults COMMAND "${Python3_EXECUTABLE}"
    "${PROJECT_SOURCE_DIR}/tests/native_stage_defaults_test.py")
endif()

if(APPLE AND (WAM_ENABLE_AVCODEC_STAGE OR WAM_ENABLE_AVFORMAT_STAGE))
  add_library(wam_coexistence_fake_mpv SHARED fakes/mpv_runtime/fake_mpv.cpp)
  target_compile_definitions(wam_coexistence_fake_mpv PRIVATE WAM_FAKE_MPV_NEWER_MINOR=1)
  target_link_libraries(wam_coexistence_fake_mpv PRIVATE wam_mpv_headers)
  set_target_properties(wam_coexistence_fake_mpv PROPERTIES PREFIX "" SUFFIX "" OUTPUT_NAME ${WAM_MPV_FALLBACK_DYLIB})
  add_executable(wam_ffmpeg_coexistence_test ffmpeg_coexistence_test.cpp)
  target_link_libraries(wam_ffmpeg_coexistence_test PRIVATE wam_avcodec_worker wam_mpv_runtime)
  add_test(NAME ffmpeg_coexistence COMMAND wam_ffmpeg_coexistence_test "$<TARGET_FILE:wam_coexistence_fake_mpv>")
endif()

if(APPLE)
  add_executable(wam_native_late_frame_json_test
    native_late_frame_json_test.cpp ${PROJECT_SOURCE_DIR}/src/qt/native_playback_metrics.cpp)
  target_include_directories(wam_native_late_frame_json_test PRIVATE ${PROJECT_SOURCE_DIR}/src)
  target_compile_definitions(wam_native_late_frame_json_test PRIVATE WAM_NATIVE_BENCHMARK_TELEMETRY=1)
  add_test(NAME native_late_frame_json
    COMMAND "${Python3_EXECUTABLE}" "${PROJECT_SOURCE_DIR}/tests/native_late_frame_json_test.py"
      "$<TARGET_FILE:wam_native_late_frame_json_test>")
endif()

if(APPLE AND WAM_ENABLE_MACOS_NATIVE_VIDEO)
  add_executable(wam_native_phase2g_video_test native_phase2g_video_test.mm)
  target_link_libraries(wam_native_phase2g_video_test PRIVATE wam_macos_native_backend)
  target_compile_options(wam_native_phase2g_video_test PRIVATE -fobjc-arc -Wno-deprecated-declarations)
  foreach(case IN ITEMS 444-601 444-709 hlg-h264-ambient)
    add_test(NAME native_phase2g_${case} COMMAND wam_native_phase2g_video_test
      "${PROJECT_SOURCE_DIR}/tests/fixtures/native-phase2g/${case}.mp4")
  endforeach()
endif()

if(APPLE AND WAM_ENABLE_MACOS_NATIVE_VIDEO)
  add_executable(wam_native_process_registry_exit_test native_process_registry_exit_test.mm)
  target_link_libraries(wam_native_process_registry_exit_test PRIVATE wam_macos_native_backend)
  target_compile_options(wam_native_process_registry_exit_test PRIVATE -fobjc-arc)
  foreach(registry IN ITEMS audio video)
    add_test(NAME native_process_registry_${registry}_exit COMMAND wam_native_process_registry_exit_test ${registry})
  endforeach()
endif()

if(APPLE AND WAM_ENABLE_MACOS_NATIVE_VIDEO)
  add_executable(wam_native_rational_display_test native_rational_display_test.mm)
  target_compile_options(wam_native_rational_display_test PRIVATE -fobjc-arc -UNDEBUG)
  target_link_libraries(wam_native_rational_display_test PRIVATE wam_macos_native_layer wam_native_core)
  add_test(NAME native_rational_display COMMAND wam_native_rational_display_test)
endif()

if(APPLE AND WAM_ENABLE_MACOS_NATIVE_VIDEO AND WAM_NATIVE_BENCHMARK_TELEMETRY)
# Quiet UI regressions use only generated, silent media and the in-process
# window seam; run serially so probes do not compete for native admission.
  foreach(ui_case refusal pending failed rapid skip replay volume mute subtitles transport rate truncated menu metrics gapseek badscript)
    add_test(NAME ui_${ui_case}
      COMMAND "${Python3_EXECUTABLE}" "${PROJECT_SOURCE_DIR}/tests/ui_regression_test.py"
        --app "$<TARGET_FILE:wam>" --ffmpeg "${WAM_TEST_FFMPEG}" --case "${ui_case}"
        --output "${PROJECT_BINARY_DIR}/ui-evidence/${ui_case}")
    # The harness bounds every launch (and samples a hung one), so a hang
    # fails there with evidence well before this backstop.
    set_tests_properties(ui_${ui_case} PROPERTIES TIMEOUT 240 RUN_SERIAL TRUE LABELS gui)
  endforeach()
endif()

if(APPLE AND WAM_ENABLE_MACOS_NATIVE_VIDEO AND WAM_NATIVE_BENCHMARK_TELEMETRY)
  add_test(NAME macos_video_service_lifetime
    COMMAND "${Python3_EXECUTABLE}" "${PROJECT_SOURCE_DIR}/tests/video_service_lifetime_test.py"
      "$<TARGET_BUNDLE_DIR:wam>" --ffmpeg "${WAM_TEST_FFMPEG}")
  set_tests_properties(macos_video_service_lifetime PROPERTIES TIMEOUT 300 RUN_SERIAL TRUE)
  add_test(NAME macos_startup_launch
    COMMAND "${Python3_EXECUTABLE}" "${PROJECT_SOURCE_DIR}/tests/startup_launch_test.py"
      "$<TARGET_BUNDLE_DIR:wam>" --ffmpeg "${WAM_TEST_FFMPEG}")
  set_tests_properties(macos_startup_launch PROPERTIES TIMEOUT 180 RUN_SERIAL TRUE LABELS gui)
endif()

if(APPLE AND WAM_ENABLE_MACOS_NATIVE_VIDEO)
  # Diagnostic, not a CTest: its window mode intentionally reproduces an OS leak.
  add_executable(wam_video_service_os_probe EXCLUDE_FROM_ALL video_service_os_probe.mm)
  target_compile_features(wam_video_service_os_probe PRIVATE cxx_std_20)
  target_compile_options(wam_video_service_os_probe PRIVATE -fobjc-arc -Wno-deprecated-declarations)
  target_link_libraries(wam_video_service_os_probe PRIVATE
    "${WAM_APPKIT_FRAMEWORK}" "${WAM_AVFOUNDATION_FRAMEWORK}"
    "${WAM_VIDEOTOOLBOX_FRAMEWORK}" "${WAM_COREMEDIA_FRAMEWORK}" "${WAM_COREVIDEO_FRAMEWORK}"
    "${WAM_OPENGL_FRAMEWORK}")
endif()

if(WAM_ENABLE_AVCODEC_STAGE)
  get_property(wam_tests_before_avcodec DIRECTORY PROPERTY TESTS)
  add_executable(wam_avcodec_admission_queue_test avcodec_admission_queue_test.cpp)
  target_link_libraries(wam_avcodec_admission_queue_test PRIVATE wam_avcodec_worker)
  add_test(NAME avcodec_admission_queue COMMAND wam_avcodec_admission_queue_test)
  set_tests_properties(avcodec_admission_queue PROPERTIES TIMEOUT 30)
  add_executable(wam_avcodec_worker_test avcodec_worker_test.cpp)
  target_link_libraries(wam_avcodec_worker_test PRIVATE wam_avcodec_worker)
  foreach(specimen IN ITEMS hi10p h264422 asp)
    if(specimen STREQUAL "asp")
      set(codec mpeg4)
    else()
      set(codec h264)
    endif()
    add_test(NAME avcodec_worker_${specimen} COMMAND wam_avcodec_worker_test
      "${PROJECT_BINARY_DIR}/test-media/native-coverage/phase2/${specimen}.packets" "${codec}")
    set_tests_properties(avcodec_worker_${specimen} PROPERTIES TIMEOUT 30)
  endforeach()

  add_executable(wam_software_avcodec_video_test software_avcodec_video_test.mm)
  target_link_libraries(wam_software_avcodec_video_test PRIVATE wam_macos_native_video_core)
  foreach(specimen IN ITEMS hi10p h264422 asp vp9 vp9p2)
    add_test(NAME software_avcodec_video_${specimen} COMMAND wam_software_avcodec_video_test
      "${PROJECT_BINARY_DIR}/test-media/native-coverage/phase2/${specimen}.packets" "${specimen}")
    set_tests_properties(software_avcodec_video_${specimen} PROPERTIES TIMEOUT 30)
  endforeach()

  add_test(NAME avcodec_fixtures COMMAND "${Python3_EXECUTABLE}"
    "${PROJECT_SOURCE_DIR}/tests/native_avcodec_fixtures.py"
    --output "${PROJECT_BINARY_DIR}/test-media/native-coverage/phase2"
    --ffmpeg "${WAM_TEST_FFMPEG}" --ffprobe "${WAM_TEST_FFPROBE}")
  set_tests_properties(avcodec_fixtures PROPERTIES
    FIXTURES_SETUP avcodec_media RUN_SERIAL TRUE RESOURCE_LOCK avcodec_fixture_generation TIMEOUT 120)
  add_test(NAME avcodec_packaging_audit COMMAND "${Python3_EXECUTABLE}"
    "${PROJECT_SOURCE_DIR}/tests/native_avcodec_packaging_audit_test.py")
  add_test(NAME avcodec_fixture_transaction COMMAND "${Python3_EXECUTABLE}"
    "${PROJECT_SOURCE_DIR}/tests/native_avcodec_fixture_transaction_test.py")
  set_tests_properties(avcodec_worker_hi10p avcodec_worker_h264422 avcodec_worker_asp
    software_avcodec_video_hi10p software_avcodec_video_h264422 software_avcodec_video_asp
    software_avcodec_video_vp9 software_avcodec_video_vp9p2
    PROPERTIES FIXTURES_REQUIRED avcodec_media)
  add_executable(wam_software_avcodec_audio_test software_avcodec_audio_test.cpp
    ${PROJECT_SOURCE_DIR}/src/platform/macos/software_avcodec_audio_backend.cpp)
  target_compile_definitions(wam_software_avcodec_audio_test PRIVATE WAM_AVCODEC_AUDIO_TESTING=1)
  target_link_libraries(wam_software_avcodec_audio_test PRIVATE wam_avcodec_worker)
  target_sources(wam_software_avcodec_audio_test PRIVATE ${PROJECT_SOURCE_DIR}/src/media/audio_downmix.cpp)
  foreach(specimen IN ITEMS dts truehd mlp)
    add_test(NAME software_avcodec_audio_${specimen} COMMAND wam_software_avcodec_audio_test
      "${PROJECT_BINARY_DIR}/test-media/native-coverage/phase2/${specimen}.audio-packets"
      "${PROJECT_BINARY_DIR}/test-media/native-coverage/phase2/${specimen}.f32" "${specimen}")
    set_tests_properties(software_avcodec_audio_${specimen} PROPERTIES FIXTURES_REQUIRED avcodec_media TIMEOUT 30)
  endforeach()

  add_executable(wam_avcodec_runtime_test avcodec_runtime_test.cpp)
  target_link_libraries(wam_avcodec_runtime_test PRIVATE wam_avcodec_worker)
  add_test(NAME avcodec_runtime COMMAND wam_avcodec_runtime_test)
  add_test(NAME avcodec_runtime_relocation COMMAND "${Python3_EXECUTABLE}"
    "${PROJECT_SOURCE_DIR}/tests/avcodec_runtime_relocation.py"
    --binary "$<TARGET_FILE:wam_avcodec_runtime_test>"
    --libraries "${PROJECT_BINARY_DIR}/native-codecs")

  add_library(wam_avcodec_instrumented STATIC
    ${PROJECT_SOURCE_DIR}/src/media/avcodec/decode_worker.cpp ${PROJECT_SOURCE_DIR}/src/media/avcodec/runtime.cpp)
  target_include_directories(wam_avcodec_instrumented PUBLIC ${PROJECT_SOURCE_DIR}/src)
  target_compile_features(wam_avcodec_instrumented PUBLIC cxx_std_20)
  target_compile_definitions(wam_avcodec_instrumented PRIVATE WAM_AVCODEC_ALLOCATION_PROBE=1)
  target_link_libraries(wam_avcodec_instrumented PUBLIC wam_ffmpeg_lgpl)
  add_library(wam_avcodec_probe_hooks SHARED avcodec_allocation_probe.cpp)
  target_include_directories(wam_avcodec_probe_hooks PRIVATE ${PROJECT_SOURCE_DIR}/src)
  target_compile_definitions(wam_avcodec_probe_hooks PRIVATE WAM_AVCODEC_ALLOCATION_PROBE=1)
  target_link_libraries(wam_avcodec_instrumented PUBLIC wam_avcodec_probe_hooks)
  add_executable(wam_avcodec_allocation_test avcodec_worker_test.cpp)
  target_compile_definitions(wam_avcodec_allocation_test PRIVATE WAM_AVCODEC_ALLOCATION_PROBE=1)
  target_link_libraries(wam_avcodec_allocation_test PRIVATE wam_avcodec_instrumented)
  add_executable(wam_avcodec_audio_allocation_test software_avcodec_audio_test.cpp
    ${PROJECT_SOURCE_DIR}/src/platform/macos/software_avcodec_audio_backend.cpp)
  target_compile_definitions(wam_avcodec_audio_allocation_test PRIVATE
    WAM_AVCODEC_ALLOCATION_PROBE=1 WAM_AVCODEC_AUDIO_TESTING=1)
  target_link_libraries(wam_avcodec_audio_allocation_test PRIVATE wam_avcodec_instrumented)
  target_sources(wam_avcodec_audio_allocation_test PRIVATE ${PROJECT_SOURCE_DIR}/src/media/audio_downmix.cpp)

  foreach(specimen IN ITEMS dts51 truehd51)
    add_test(NAME software_avcodec_audio_${specimen} COMMAND wam_software_avcodec_audio_test
      "${PROJECT_BINARY_DIR}/test-media/native-coverage/phase2/${specimen}.audio-packets"
      "${PROJECT_BINARY_DIR}/test-media/native-coverage/phase2/${specimen}.f32" "${specimen}" 6
      "${PROJECT_BINARY_DIR}/test-media/native-coverage/phase2/${specimen}.stereo.f32")
    set_tests_properties(software_avcodec_audio_${specimen} PROPERTIES FIXTURES_REQUIRED avcodec_media TIMEOUT 30)
  endforeach()

  add_executable(wam_avcodec_video_allocation_test software_avcodec_video_test.mm)
  target_link_libraries(wam_avcodec_video_allocation_test PRIVATE
    wam_avcodec_instrumented wam_macos_native_video_core)
  add_test(NAME avcodec_allocation_attribution COMMAND "${Python3_EXECUTABLE}"
    "${PROJECT_SOURCE_DIR}/tests/avcodec_allocation_attribution_test.py"
    "$<TARGET_FILE:wam_avcodec_video_allocation_test>"
    "${PROJECT_BINARY_DIR}/test-media/native-coverage/phase2/asp.packets" asp)
  set_tests_properties(avcodec_allocation_attribution PROPERTIES FIXTURES_REQUIRED avcodec_media TIMEOUT 45)

  add_executable(wam_avcodec_worker_budget_test avcodec_worker_budget_test.cpp)
  target_link_libraries(wam_avcodec_worker_budget_test PRIVATE wam_avcodec_worker)
  add_test(NAME avcodec_worker_budget COMMAND wam_avcodec_worker_budget_test)

  add_executable(wam_software_avcodec_surface_contention_test
    software_avcodec_surface_contention_test.mm
    ${PROJECT_SOURCE_DIR}/src/platform/macos/native_surface_budget.mm)
  target_compile_definitions(wam_software_avcodec_surface_contention_test PRIVATE
    WAM_NATIVE_SURFACE_BUDGET_TESTING=1)
  target_link_libraries(wam_software_avcodec_surface_contention_test PRIVATE
    wam_macos_native_video_core)
  add_test(NAME software_avcodec_surface_contention
    COMMAND wam_software_avcodec_surface_contention_test
      "${PROJECT_BINARY_DIR}/test-media/native-coverage/phase2/asp.packets")
  set_tests_properties(software_avcodec_surface_contention PROPERTIES
    FIXTURES_REQUIRED avcodec_media TIMEOUT 30)

  add_test(NAME software_audio_production COMMAND "${Python3_EXECUTABLE}"
    "${PROJECT_SOURCE_DIR}/tests/software_audio_production_proof.py"
    --probe "$<TARGET_FILE:wam_native_coverage_audio_probe>"
    --fixtures "${PROJECT_BINARY_DIR}/test-media/native-coverage/phase2"
    --ffmpeg "${WAM_TEST_FFMPEG}"
    --output "${PROJECT_BINARY_DIR}/software-audio-production.json")
  set_tests_properties(software_audio_production PROPERTIES FIXTURES_REQUIRED avcodec_media TIMEOUT 120)

  add_executable(wam_software_decoder_reservation_test software_decoder_reservation_test.cpp)
  target_link_libraries(wam_software_decoder_reservation_test PRIVATE wam_avcodec_worker)
  add_test(NAME software_decoder_reservation COMMAND wam_software_decoder_reservation_test)
  set_tests_properties(software_decoder_reservation PROPERTIES TIMEOUT 30)

  add_test(NAME ffmpeg_reservation_allocator COMMAND "${Python3_EXECUTABLE}"
    "${PROJECT_SOURCE_DIR}/tests/ffmpeg_reservation_proof.py")
  add_test(NAME ffmpeg_reservation_unload COMMAND "${Python3_EXECUTABLE}"
    "${PROJECT_SOURCE_DIR}/tests/ffmpeg_reservation_loader_proof.py")
  get_property(wam_avcodec_tests DIRECTORY PROPERTY TESTS)
  list(REMOVE_ITEM wam_avcodec_tests ${wam_tests_before_avcodec})
  set_property(TEST ${wam_avcodec_tests} APPEND PROPERTY LABELS avcodec)
endif()

if(WAM_ENABLE_AVFORMAT_STAGE)
  add_executable(wam_libavformat_source_test libavformat_source_test.mm)
  target_link_libraries(wam_libavformat_source_test PRIVATE wam_macos_native_backend)
  add_test(NAME libavformat_mpeg4_full_range COMMAND wam_libavformat_source_test
    "${PROJECT_SOURCE_DIR}/tests/fixtures/software-color/asp-full.mkv"
    "ready")
  set(WAM_AVFORMAT_FIXTURES "${PROJECT_BINARY_DIR}/test-media/native-coverage/phase3"
    CACHE PATH "Generated libavformat test corpus")
  set(WAM_MIXED_FIXTURES "${PROJECT_BINARY_DIR}/test-media/native-coverage/phase2e"
    CACHE PATH "Generated mixed-container test corpus")
  add_test(NAME libavformat_fixtures COMMAND "${Python3_EXECUTABLE}"
    "${PROJECT_SOURCE_DIR}/tests/libavformat_fixtures.py" --root "${WAM_AVFORMAT_FIXTURES}"
    --ffmpeg "${WAM_TEST_FFMPEG}")
  set_tests_properties(libavformat_fixtures PROPERTIES FIXTURES_SETUP avformat_media TIMEOUT 120)
  foreach(specimen IN ITEMS fragmented.mp4 boundary.mp4 mid-moof.mp4 mid-mdat.mp4 asp.avi)
    add_test(NAME libavformat_source_${specimen} COMMAND wam_libavformat_source_test
      "${WAM_AVFORMAT_FIXTURES}/${specimen}" ready)
    set_tests_properties(libavformat_source_${specimen} PROPERTIES FIXTURES_REQUIRED avformat_media TIMEOUT 30)
  endforeach()
  add_test(NAME libavformat_missing_init COMMAND wam_libavformat_source_test
    "${WAM_AVFORMAT_FIXTURES}/missing-init.mp4"
    "this recording is incomplete: its initialization metadata is missing")
  set_tests_properties(libavformat_missing_init PROPERTIES FIXTURES_REQUIRED avformat_media TIMEOUT 30)

  add_executable(wam_libavformat_differential_test libavformat_differential_test.cpp)
  target_link_libraries(wam_libavformat_differential_test PRIVATE wam_avcodec_worker wam_native_core)
  foreach(container IN ITEMS mkv ts)
    add_test(NAME libavformat_differential_${container} COMMAND wam_libavformat_differential_test
      "${WAM_AVFORMAT_FIXTURES}/oracle.${container}" "${container}")
    set_tests_properties(libavformat_differential_${container} PROPERTIES FIXTURES_REQUIRED avformat_media TIMEOUT 30)
  endforeach()

  add_executable(wam_libavformat_decode_test libavformat_decode_test.mm)
  target_link_libraries(wam_libavformat_decode_test PRIVATE wam_macos_native_backend)

  add_executable(wam_libavformat_contract_test libavformat_contract_test.cpp)
  target_link_libraries(wam_libavformat_contract_test PRIVATE wam_avcodec_worker)
  add_test(NAME libavformat_contract COMMAND wam_libavformat_contract_test)

  add_test(NAME libavformat_avi_missing_pts COMMAND wam_libavformat_source_test
    "${WAM_AVFORMAT_FIXTURES}/reordered-asp.avi" "LibavformatExactVideoTimelineUnavailable")
  add_test(NAME libavformat_flv_audio_refusal COMMAND wam_libavformat_source_test
    "${WAM_MIXED_FIXTURES}/positive-aac.flv" "LibavformatAudioTimingUnproven: aac")
  add_test(NAME libavformat_asf_audio_refusal COMMAND wam_libavformat_source_test
    "${WAM_AVFORMAT_FIXTURES}/legacy.asf" "LibavformatAudioTimingUnproven: wmav2")
  add_test(NAME libavformat_routed_avi COMMAND wam_libavformat_source_test
    "${WAM_AVFORMAT_FIXTURES}/asp.avi" ready routed)
  set_tests_properties(libavformat_avi_missing_pts libavformat_flv_audio_refusal
    libavformat_asf_audio_refusal libavformat_routed_avi PROPERTIES FIXTURES_REQUIRED avformat_media TIMEOUT 30)

  add_test(NAME libavformat_opus_audio_exact COMMAND "${Python3_EXECUTABLE}"
    "${PROJECT_SOURCE_DIR}/tests/libavformat_audio_proof.py"
    --probe "$<TARGET_FILE:wam_native_coverage_audio_probe>"
    --asset "${WAM_AVFORMAT_FIXTURES}/opus.ogg" --ffmpeg "${WAM_TEST_FFMPEG}"
    --output "${PROJECT_BINARY_DIR}/libavformat-audio-proof.json")
  set_tests_properties(libavformat_opus_audio_exact PROPERTIES FIXTURES_REQUIRED avformat_media TIMEOUT 60)

  add_test(NAME libavformat_routed_header_stripping COMMAND wam_libavformat_source_test
    "${WAM_AVFORMAT_FIXTURES}/header-stripped.mkv" ready routed)
  set_tests_properties(libavformat_routed_header_stripping PROPERTIES FIXTURES_REQUIRED avformat_media TIMEOUT 30)

  add_library(wam_libavformat_allocation_hooks SHARED avcodec_allocation_probe.cpp)
  target_include_directories(wam_libavformat_allocation_hooks PRIVATE ${PROJECT_SOURCE_DIR}/src)
  target_compile_definitions(wam_libavformat_allocation_hooks PRIVATE WAM_AVCODEC_ALLOCATION_PROBE=1)
  add_executable(wam_libavformat_allocation_test libavformat_allocation_test.mm)
  target_compile_definitions(wam_libavformat_allocation_test PRIVATE WAM_AVCODEC_ALLOCATION_PROBE=1)
  target_link_libraries(wam_libavformat_allocation_test PRIVATE
    wam_macos_native_backend wam_libavformat_allocation_hooks)
  add_test(NAME libavformat_vorbis_refusal COMMAND wam_libavformat_source_test
    "${WAM_AVFORMAT_FIXTURES}/vorbis.ogg" "LibavformatAudioTimingUnproven: vorbis")
  add_test(NAME libavformat_program_stream_refusal COMMAND wam_libavformat_source_test
    "${WAM_AVFORMAT_FIXTURES}/program.vob" "LibavformatAudioTimingUnproven: unmapped codec")
  set_tests_properties(libavformat_vorbis_refusal libavformat_program_stream_refusal
    PROPERTIES FIXTURES_REQUIRED avformat_media TIMEOUT 30)

  add_executable(wam_libavformat_preview_decode_test libavformat_preview_decode_test.mm)
  target_link_libraries(wam_libavformat_preview_decode_test PRIVATE wam_macos_native_backend)

  set(WAM_AVFORMAT_PREVIEW_SPECIMENS fragmented.mp4)
  if(WAM_ENABLE_AVCODEC_STAGE)
    list(APPEND WAM_AVFORMAT_PREVIEW_SPECIMENS asp.avi)
  endif()
  foreach(specimen IN LISTS WAM_AVFORMAT_PREVIEW_SPECIMENS)
    add_test(NAME libavformat_preview_decode_${specimen} COMMAND wam_libavformat_preview_decode_test
      "${WAM_AVFORMAT_FIXTURES}/${specimen}")
    set_tests_properties(libavformat_preview_decode_${specimen} PROPERTIES
      FIXTURES_REQUIRED avformat_media TIMEOUT 30)
  endforeach()

  foreach(specimen IN ITEMS mid-moof.mp4 mid-mdat.mp4)
    add_test(NAME libavformat_routed_recovery_${specimen} COMMAND wam_libavformat_source_test
      "${WAM_AVFORMAT_FIXTURES}/${specimen}" ready routed)
    set_tests_properties(libavformat_routed_recovery_${specimen} PROPERTIES
      FIXTURES_REQUIRED avformat_media TIMEOUT 30)
  endforeach()

  add_executable(wam_libavformat_mixed_audio_probe libavformat_mixed_audio_probe.mm)
  target_link_libraries(wam_libavformat_mixed_audio_probe PRIVATE wam_macos_native_backend)

  add_executable(wam_libavformat_mixed_decode_test libavformat_mixed_decode_test.mm)
  target_link_libraries(wam_libavformat_mixed_decode_test PRIVATE wam_macos_native_backend)

  add_executable(wam_libavformat_mixed_source_test libavformat_mixed_source_test.mm)
  target_link_libraries(wam_libavformat_mixed_source_test PRIVATE wam_macos_native_backend)
  add_test(NAME libavformat_mixed_fixtures COMMAND "${Python3_EXECUTABLE}"
    "${PROJECT_SOURCE_DIR}/tests/libavformat_mixed_fixtures.py" --root "${WAM_MIXED_FIXTURES}" --ffmpeg "${WAM_TEST_FFMPEG}")
  set_tests_properties(libavformat_mixed_fixtures PROPERTIES FIXTURES_SETUP mixed_media TIMEOUT 60)
  add_test(NAME libavformat_mixed_exact COMMAND "${Python3_EXECUTABLE}"
    "${PROJECT_SOURCE_DIR}/tests/libavformat_mixed_proof.py"
    --video-probe "$<TARGET_FILE:wam_libavformat_mixed_decode_test>"
    --audio-probe "$<TARGET_FILE:wam_libavformat_mixed_audio_probe>"
    --ffmpeg "${WAM_TEST_FFMPEG}" --ffprobe "${WAM_TEST_FFPROBE}"
    --output "${PROJECT_BINARY_DIR}/mixed-proof.json" --equal-endpoints
    --asset "${WAM_MIXED_FIXTURES}/mixed-fragmented.mp4" --asset "${WAM_MIXED_FIXTURES}/mixed.flv"
    --asset "${WAM_MIXED_FIXTURES}/mixed-opus.mkv")
  set_tests_properties(libavformat_mixed_exact PROPERTIES FIXTURES_REQUIRED mixed_media TIMEOUT 120)
  set_tests_properties(libavformat_flv_audio_refusal PROPERTIES FIXTURES_REQUIRED mixed_media)
  add_test(NAME libavformat_flv_audio_exact COMMAND "${Python3_EXECUTABLE}"
    "${PROJECT_SOURCE_DIR}/tests/libavformat_mixed_proof.py"
    --video-probe "$<TARGET_FILE:wam_libavformat_mixed_decode_test>"
    --audio-probe "$<TARGET_FILE:wam_libavformat_mixed_audio_probe>"
    --ffmpeg "${WAM_TEST_FFMPEG}" --ffprobe "${WAM_TEST_FFPROBE}"
    --output "${PROJECT_BINARY_DIR}/phase3-flv-proof.json" --asset "${WAM_AVFORMAT_FIXTURES}/h264-aac.flv")
  set_tests_properties(libavformat_flv_audio_exact PROPERTIES FIXTURES_REQUIRED avformat_media TIMEOUT 30)
  add_test(NAME libavformat_mixed_routed COMMAND wam_libavformat_mixed_source_test "${WAM_MIXED_FIXTURES}/mixed-fragmented.mp4")
  add_test(NAME libavformat_opus_mode_refusal COMMAND wam_libavformat_source_test "${WAM_MIXED_FIXTURES}/mixed-hybrid.mkv" "LibavformatOpusModeUnqualified")
  set_tests_properties(libavformat_mixed_routed libavformat_opus_mode_refusal PROPERTIES FIXTURES_REQUIRED mixed_media TIMEOUT 30)

  add_executable(wam_libavformat_aac_oracle libavformat_aac_oracle.mm)
  target_compile_options(wam_libavformat_aac_oracle PRIVATE -fobjc-arc)
  target_compile_features(wam_libavformat_aac_oracle PRIVATE cxx_std_20)
  target_link_libraries(wam_libavformat_aac_oracle PRIVATE
    "-framework AVFoundation" "-framework Foundation" "-framework CoreMedia")
  add_test(NAME libavformat_aac_timing COMMAND "${Python3_EXECUTABLE}"
    "${PROJECT_SOURCE_DIR}/tests/libavformat_aac_timing_proof.py"
    --probe "$<TARGET_FILE:wam_libavformat_mixed_audio_probe>"
    --routed-probe "$<TARGET_FILE:wam_native_coverage_audio_probe>"
    --oracle "$<TARGET_FILE:wam_libavformat_aac_oracle>"
    --ffmpeg "${WAM_TEST_FFMPEG}"
    --scratch "${PROJECT_BINARY_DIR}"
    --output "${PROJECT_BINARY_DIR}/libavformat-aac-timing.json")
  set_tests_properties(libavformat_aac_timing PROPERTIES TIMEOUT 180)
endif()

# Labels name what a test needs from its environment, so each runner can
# exclude what it cannot provide (for example `ctest -LE 'gui|gpu'`):
#   gui            launches WAM.app with windows (also the ui_* cases)
#   gpu            needs an accelerated OpenGL display (skips on hosted VMs)
#   hardware       needs hardware video decoding
#   fixtures-local needs media supplied at configure time
#   avcodec        exercises the default-off libavcodec stage (labelled above)
foreach(label_and_tests IN ITEMS
    "gui;native_coverage_wiring;macos_video_service_lifetime"
    "gpu;macos_native_qt_gl_compositor;macos_native_qt_gl_output;player_core_render_context_permission"
    "hardware;macos_video_toolbox_decoder;macos_native_headless_performance;macos_native_phase0b_integration"
    "fixtures-local;macos_video_toolbox_decoder;macos_native_headless_performance")
  list(POP_FRONT label_and_tests label)
  foreach(test IN LISTS label_and_tests)
    if(TEST ${test})
      set_property(TEST ${test} APPEND PROPERTY LABELS ${label})
    endif()
  endforeach()
endforeach()
