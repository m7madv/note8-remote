package com.codex.note8remote;

/** Bounded end-to-end window; acknowledgements come after display preparation. */
final class FrameWindow {
    private long sent, acknowledged;
    synchronized long reserve() {
        if(sent-acknowledged>=2)return 0;
        return ++sent;
    }
    synchronized void acknowledge(long value) {
        if(value>acknowledged && value<=sent)acknowledged=value;
    }
    synchronized void reset(){acknowledged=sent;}
}
