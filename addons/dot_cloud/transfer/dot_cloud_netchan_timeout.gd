class_name DotCloudNetchanTimeout
extends RefCounted

## Marker returned by [method DotCloudSourceNetchan._request_chunk] when a chunk
## request outlived [member DotCloudSourceNetchan.chunk_timeout_sec].
##
## A distinct type rather than [code]null[/code] or a pre-built failed
## [DotResult]: the delegate is allowed to return either of those to mean its own
## things — [code]null[/code] already means "the server did not answer" — and the
## caller has to keep the partial file on a timeout while discarding it on some
## other failures. Two meanings sharing one value is how that distinction gets
## lost in a later edit.
