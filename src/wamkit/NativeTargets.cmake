if(APPLE)
  add_library(wam_native_core STATIC
    src/media/matroska_aac.hpp
    src/media/matroska_aac.cpp
    src/media/audio_codec_timing.hpp
    src/media/media_codec_facts.hpp
    src/media/media_iso_color.hpp
    src/media/audio_downmix.hpp
    src/media/audio_downmix.cpp
    src/media/matroska_opus.hpp
    src/media/matroska_opus.cpp
    src/media/matroska_vorbis.hpp
    src/media/matroska_vorbis.cpp
    src/media/matroska_ac3.hpp
    src/media/matroska_ac3.cpp
    src/media/matroska_flac.hpp
    src/media/matroska_flac.cpp
    src/media/matroska_mpeg_audio.hpp
    src/media/matroska_mpeg_audio.cpp
    src/media/matroska_ebml.hpp
    src/media/matroska_ebml.cpp
    src/media/matroska_demuxer.hpp
    src/media/matroska_demuxer.cpp
    src/media/subtitle_text.hpp
    src/media/subtitle_text.cpp
    src/media/subtitle_bitmap.hpp
    src/media/subtitle_bitmap.cpp
    src/media/subtitle_pgs.hpp
    src/media/subtitle_pgs.cpp
    src/media/subtitle_vobsub.hpp
    src/media/subtitle_vobsub.cpp
    src/media/matroska_subtitles.hpp
    src/media/matroska_subtitles.cpp
    src/media/tx3g_text.hpp
    src/media/tx3g_text.cpp
    src/media/mp4_subtitles.hpp
    src/media/mp4_subtitles.cpp
    src/media/h264_caption_sei.hpp
    src/media/h264_caption_sei.cpp
    src/media/cea608_decoder.hpp
    src/media/cea608_decoder.cpp
    src/media/live_caption_feed.hpp
    src/media/live_caption_feed.cpp
    src/media/mpegts_packet.hpp
    src/media/mpegts_packet.cpp
    src/media/mpegts_demuxer.hpp
    src/media/mpegts_demuxer.cpp
    src/media/video_codec_configuration.hpp
    src/media/video_codec_configuration.cpp
    src/media/native_media_source.hpp
    src/media/native_media_source.cpp
    src/media/native_media_backend.hpp
    src/media/native_media_backend.cpp
    src/media/native_media_dispatcher.hpp
    src/media/native_media_dispatcher.cpp
    src/media/native_playback_contract.hpp
    src/media/playback_router.hpp
    src/media/playback_router.cpp
    src/platform/macos/native_media_clock.hpp
    src/platform/macos/native_media_clock.cpp
    src/platform/macos/native_pcm_ring.hpp
    src/platform/macos/native_pcm_ring.cpp
    src/platform/macos/native_audio_render_core.hpp
    src/platform/macos/native_audio_render_core.cpp)
  target_include_directories(wam_native_core PUBLIC src)
  target_compile_features(wam_native_core PUBLIC cxx_std_20)
  target_compile_options(wam_native_core PRIVATE
    -Wall -Wextra -Wpedantic)
  if(WAM_ENABLE_SOFTWARE_VP8)
    # The demuxer must not name V_VP8 in a build whose platform layer cannot
    # decode it: admitting the track and then failing the open is a worse
    # fallback than never selecting it.
    target_compile_definitions(wam_native_core PUBLIC WAM_ENABLE_SOFTWARE_VP8)
  endif()
endif()

if(APPLE)
find_library(WAM_COREFOUNDATION_FRAMEWORK CoreFoundation REQUIRED)
find_library(WAM_COREMEDIA_FRAMEWORK CoreMedia REQUIRED)
find_library(WAM_COREVIDEO_FRAMEWORK CoreVideo REQUIRED)
find_library(WAM_FOUNDATION_FRAMEWORK Foundation REQUIRED)
find_library(WAM_IOSURFACE_FRAMEWORK IOSurface REQUIRED)
find_library(WAM_VIDEOTOOLBOX_FRAMEWORK VideoToolbox REQUIRED)
find_library(WAM_COREGRAPHICS_FRAMEWORK CoreGraphics REQUIRED)
find_library(WAM_APPKIT_FRAMEWORK AppKit REQUIRED)
find_library(WAM_AUDIOTOOLBOX_FRAMEWORK AudioToolbox REQUIRED)
find_library(WAM_COREAUDIO_FRAMEWORK CoreAudio REQUIRED)
find_library(WAM_AVFOUNDATION_FRAMEWORK AVFoundation REQUIRED)
find_library(WAM_QUARTZCORE_FRAMEWORK QuartzCore REQUIRED)
find_library(WAM_COREIMAGE_FRAMEWORK CoreImage REQUIRED)
  set(WAM_MACOS_NATIVE_VIDEO_CORE_SOURCES
    src/platform/macos/native_surface_budget.hpp
    src/platform/macos/native_surface_budget.mm
    src/platform/macos/native_video_codec_capability.hpp
    src/platform/macos/native_video_codec_capability.mm
    src/platform/macos/native_video_limits.hpp
    src/platform/macos/native_video_presenter.hpp
    src/platform/macos/native_video_presenter.mm
    src/platform/macos/video_toolbox_decoder.hpp
    src/platform/macos/video_toolbox_decoder.mm
    src/platform/macos/software_vp8_decoder.hpp
    src/platform/macos/software_vp8_decoder.mm
    src/platform/macos/video_decode_lane.hpp)
  add_library(wam_macos_native_video_core STATIC
    ${WAM_MACOS_NATIVE_VIDEO_CORE_SOURCES})
  target_include_directories(wam_macos_native_video_core PUBLIC src)
  target_compile_features(wam_macos_native_video_core PUBLIC cxx_std_20)
  target_compile_options(wam_macos_native_video_core PRIVATE
    "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
    -Wall -Wextra -Wpedantic)
  # The decoder derives an AVC stream's reorder depth through the neutral
  # configuration parser rather than a second SPS parser of its own.
  target_link_libraries(wam_macos_native_video_core PUBLIC
    wam_native_core
    "${WAM_COREFOUNDATION_FRAMEWORK}"
    "${WAM_COREMEDIA_FRAMEWORK}"
    "${WAM_COREVIDEO_FRAMEWORK}"
    "${WAM_FOUNDATION_FRAMEWORK}"
    "${WAM_IOSURFACE_FRAMEWORK}"
    "${WAM_VIDEOTOOLBOX_FRAMEWORK}")
  if(WAM_ENABLE_SOFTWARE_VP8)
    target_compile_definitions(wam_macos_native_video_core PUBLIC
      WAM_ENABLE_SOFTWARE_VP8)
    target_link_libraries(wam_macos_native_video_core PUBLIC
      PkgConfig::WAM_LIBVPX)
  endif()
  if(WAM_ENABLE_AVCODEC_STAGE)
    target_sources(wam_macos_native_video_core PRIVATE
      src/platform/macos/software_avcodec_video_decoder.mm
      src/platform/macos/software_presentation_pool.mm)
    target_link_libraries(wam_macos_native_video_core PUBLIC wam_avcodec_worker)
    target_compile_definitions(wam_macos_native_video_core PUBLIC WAM_ENABLE_AVCODEC_STAGE=1)
    target_compile_definitions(wam_native_core PRIVATE WAM_ENABLE_AVCODEC_STAGE=1)
  endif()
  set_target_properties(wam_macos_native_video_core PROPERTIES
    LINKER_LANGUAGE OBJCXX)

  add_library(wam_macos_native_layer STATIC
    src/platform/macos/native_layer_video_output.hpp
    src/platform/macos/native_layer_video_output.mm
    src/platform/macos/native_layer_host_view.hpp
    src/platform/macos/native_layer_host_view.mm
    src/platform/macos/native_embedding_support.mm)
  target_include_directories(wam_macos_native_layer PUBLIC src)
  target_compile_features(wam_macos_native_layer PUBLIC cxx_std_20)
  target_compile_options(wam_macos_native_layer PRIVATE
    "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>" -Wall -Wextra -Wpedantic)
  target_link_libraries(wam_macos_native_layer PUBLIC wam_macos_native_video_core
    "-framework AppKit" "-framework AVFoundation" "-framework QuartzCore" "-framework CoreImage")

    set(WAM_MACOS_NATIVE_BACKEND_SOURCES
      src/platform/macos/core_media_source_support.hpp
      src/platform/macos/native_custom_source_core.hpp
      src/platform/macos/avfoundation_asset_context.hpp
      src/platform/macos/avfoundation_asset_context.mm
      src/platform/macos/avfoundation_media_source.hpp
      src/platform/macos/avfoundation_media_source.mm
      src/platform/macos/avfoundation_preview_source.hpp
      src/platform/macos/avfoundation_preview_source.mm
      src/platform/macos/matroska_asset_context.hpp
      src/platform/macos/matroska_asset_context.cpp
      src/platform/macos/matroska_media_source.hpp
      src/platform/macos/matroska_media_source.mm
      src/platform/macos/matroska_preview_source.hpp
      src/platform/macos/matroska_preview_source.mm
      src/platform/macos/matroska_sample_builder.hpp
      src/platform/macos/matroska_sample_builder.mm
      src/platform/macos/mpegts_asset_context.hpp
      src/platform/macos/mpegts_asset_context.cpp
      src/platform/macos/mpegts_media_source.hpp
      src/platform/macos/mpegts_media_source.mm
      src/platform/macos/mpegts_preview_source.hpp
      src/platform/macos/mpegts_preview_source.mm
      src/platform/macos/mpegts_sample_builder.hpp
      src/platform/macos/mpegts_sample_builder.mm
      src/platform/macos/native_preview_source.hpp
      src/platform/macos/native_preview_source.mm
      src/platform/macos/native_audio_converter.hpp
      src/platform/macos/native_audio_converter.mm
      src/platform/macos/native_audio_output.hpp
      src/platform/macos/native_audio_output.mm
      src/platform/macos/native_audio_stretch_stage.hpp
      src/platform/macos/native_audio_stretch_stage.mm
      src/platform/macos/native_audio_session.hpp
      src/platform/macos/native_audio_session.mm
      src/platform/macos/native_media_session.hpp
      src/platform/macos/native_media_session.mm
      src/platform/macos/native_silent_timebase.hpp
      src/platform/macos/native_silent_timebase.cpp
      src/platform/macos/native_preview_frame_lane.hpp
      src/platform/macos/native_preview_frame_lane.mm
      src/platform/macos/native_tracked_video_arbiter.hpp
      src/platform/macos/native_tracked_video_arbiter.mm
      src/platform/macos/native_tracked_video_output.hpp
      src/platform/macos/native_video_consumer.hpp
      src/platform/macos/native_video_consumer.mm)

    add_library(wam_macos_native_backend STATIC
      ${WAM_MACOS_NATIVE_BACKEND_SOURCES})
    if(WAM_ENABLE_AVFORMAT_STAGE)
      target_link_libraries(wam_macos_native_backend PUBLIC wam_avcodec_worker)
      target_sources(wam_avcodec_worker PRIVATE src/media/libavformat_cursor.cpp)
      target_sources(wam_macos_native_backend PRIVATE
        src/platform/macos/libavformat_media_source.mm
        src/platform/macos/routed_media_source.mm)
      target_compile_definitions(wam_macos_native_backend PUBLIC WAM_ENABLE_AVFORMAT_STAGE=1)
    endif()
    target_include_directories(wam_macos_native_backend PUBLIC src)
    target_compile_features(wam_macos_native_backend PUBLIC cxx_std_20)
    target_compile_options(wam_macos_native_backend PRIVATE
      "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
      -Wall -Wextra -Wpedantic)
    target_link_libraries(wam_macos_native_backend PUBLIC
      wam_native_core
      wam_macos_native_video_core
      "${WAM_COREFOUNDATION_FRAMEWORK}"
      "${WAM_COREGRAPHICS_FRAMEWORK}"
      "${WAM_COREMEDIA_FRAMEWORK}"
      "${WAM_COREVIDEO_FRAMEWORK}"
      "${WAM_FOUNDATION_FRAMEWORK}"
      "${WAM_IOSURFACE_FRAMEWORK}"
      "${WAM_AUDIOTOOLBOX_FRAMEWORK}"
      "${WAM_COREAUDIO_FRAMEWORK}"
      "${WAM_AVFOUNDATION_FRAMEWORK}"
      "${WAM_VIDEOTOOLBOX_FRAMEWORK}")
    set_target_properties(wam_macos_native_backend PROPERTIES
      LINKER_LANGUAGE OBJCXX)

    add_library(wam_macos_native_session_system STATIC
      src/platform/macos/native_media_session_system.hpp
      src/platform/macos/native_media_session_system.mm
      src/platform/macos/native_playback_owner.hpp
      src/platform/macos/native_playback_owner.mm
      src/platform/macos/native_retirement.hpp
      src/platform/macos/native_retirement.mm
      src/platform/macos/native_open_preflight.hpp
      src/platform/macos/native_open_preflight.mm)
    target_include_directories(wam_macos_native_session_system PUBLIC src)
    target_compile_features(wam_macos_native_session_system PUBLIC cxx_std_20)
    target_compile_options(wam_macos_native_session_system PRIVATE
      "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
      -Wall -Wextra -Wpedantic)
    target_link_libraries(wam_macos_native_session_system
      PUBLIC
        wam_macos_native_backend)
    set_target_properties(wam_macos_native_session_system PROPERTIES
      LINKER_LANGUAGE OBJCXX)


endif()
