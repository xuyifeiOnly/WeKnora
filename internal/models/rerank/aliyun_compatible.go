package rerank

import (
	"strings"

	"github.com/Tencent/WeKnora/internal/models/api"
	"github.com/Tencent/WeKnora/internal/models/catalog"
)

// rewriteAliyunCompatibleAPIRerank maps Aliyun MAAS / compatible-api rerank
// bases onto the Cohere-shaped endpoint that actually works:
//
//	{host}/compatible-api/v1/reranks
//
// Operators commonly paste the chat/embedding base
// (`…/compatible-mode/v1`), which 404s on both `/rerank` and `/reranks`.
// Workspace hosts (`*.maas.aliyuncs.com`) and the DashScope compatible-api
// dialect share the flat {model,query,documents,top_n} request that
// cohererank already speaks — only the path root differs from
// compatible-mode.
//
// Native DashScope text-rerank URLs
// (`/api/v1/services/rerank/text-rerank/…`) are left alone for gte-rerank-v2.
func rewriteAliyunCompatibleAPIRerank(resolved *catalog.Resolved) {
	if resolved == nil {
		return
	}
	base := strings.TrimRight(resolved.BaseURL, "/")
	if base == "" {
		return
	}
	lower := strings.ToLower(base)
	if strings.Contains(lower, "/services/rerank/") {
		return
	}
	maas := strings.Contains(lower, "maas.aliyuncs.com")
	compatAPI := strings.Contains(lower, "/compatible-api")
	compatModeOnDashScope := strings.Contains(lower, "dashscope") && strings.Contains(lower, "/compatible-mode")
	if !maas && !compatAPI && !compatModeOnDashScope {
		return
	}

	root := base
	for _, marker := range []string{"/compatible-mode", "/compatible-api", "/reranks", "/rerank"} {
		if i := strings.Index(root, marker); i >= 0 {
			root = root[:i]
		}
	}
	root = strings.TrimRight(root, "/")
	if root == "" {
		return
	}

	resolved.BaseURL = root + "/compatible-api/v1"
	resolved.RerankAPI = api.RerankCohere
	resolved.Rerank.Path = "/reranks"
	resolved.Rerank.SendTopN = true
	resolved.Rerank.UnsupportedReason = ""
}
