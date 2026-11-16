#pragma once

// Call once in the Node runner, before node::Start. Not an Ark NAPI module.
void RegisterPublicationBinding();

#if defined(DSH_IOS_HOST)
// Each iOS engine run has a fresh Node thread, even after module registration.
void BindIOSLifecycleThread();
#endif
