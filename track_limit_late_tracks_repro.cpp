#define main matroska_existing_test_main
#include "/Users/wesleymaa/Documents/WAM/tests/matroska_ebml_test.cpp"
#undef main

int main() {
  Bytes segment = info();
  Bytes clusterPayload = uintElement(0xE7, 0);
  append(clusterPayload,
         simpleBlock(0x80, Bytes{std::byte{1}}, 0));
  append(segment, element(0x1F43B675, clusterPayload));
  append(segment, tracks());
  MemoryReader reader(document(segment));
  RecordingVisitor visitor;
  ParseOptions options;
  options.visitClusterBlocks = true;
  options.maximumTracks = 0;
  const auto result = parseDocument(reader, visitor, options);
  std::printf("status=%u error=%u blocks=%zu tracks=%zu offset=%llu\n",
              static_cast<unsigned>(result.status),
              static_cast<unsigned>(result.error), visitor.blocks,
              visitor.tracks,
              static_cast<unsigned long long>(result.errorOffset));
  return 0;
}
