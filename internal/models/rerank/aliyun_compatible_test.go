package rerank

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/Tencent/WeKnora/internal/models/api"
	"github.com/Tencent/WeKnora/internal/models/catalog"
)

func TestRewriteAliyunCompatibleAPIRerank(t *testing.T) {
	cases := []struct {
		name    string
		base    string
		wantURL string
		wantAPI api.RerankAPI
		rewrote bool
	}{
		{
			name:    "maas compatible-mode pasted from chat",
			base:    "https://ws-example.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
			wantURL: "https://ws-example.cn-beijing.maas.aliyuncs.com/compatible-api/v1",
			wantAPI: api.RerankCohere,
			rewrote: true,
		},
		{
			name:    "maas already on compatible-api",
			base:    "https://ws-example.cn-beijing.maas.aliyuncs.com/compatible-api/v1",
			wantURL: "https://ws-example.cn-beijing.maas.aliyuncs.com/compatible-api/v1",
			wantAPI: api.RerankCohere,
			rewrote: true,
		},
		{
			name:    "native dashscope text-rerank left alone",
			base:    "https://dashscope.aliyuncs.com/api/v1/services/rerank/text-rerank/text-rerank",
			wantURL: "https://dashscope.aliyuncs.com/api/v1/services/rerank/text-rerank/text-rerank",
			wantAPI: api.RerankDashScope,
			rewrote: false,
		},
		{
			name:    "unrelated host untouched",
			base:    "https://api.jina.ai/v1",
			wantURL: "https://api.jina.ai/v1",
			wantAPI: api.RerankCohere,
			rewrote: false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			resolved := &catalog.Resolved{
				BaseURL:   tc.base,
				RerankAPI: tc.wantAPI,
				Rerank:    catalog.DefaultRerank(),
			}
			if tc.rewrote {
				// Start from DashScope so the rewrite must flip the protocol.
				resolved.RerankAPI = api.RerankDashScope
			}
			rewriteAliyunCompatibleAPIRerank(resolved)
			assert.Equal(t, tc.wantURL, resolved.BaseURL)
			assert.Equal(t, tc.wantAPI, resolved.RerankAPI)
			if tc.rewrote {
				assert.Equal(t, "/reranks", resolved.Rerank.Path)
				assert.True(t, resolved.Rerank.SendTopN)
			} else {
				assert.Empty(t, resolved.Rerank.Path)
			}
		})
	}
}

func TestRewriteAliyunCompatibleAPIRerankNilSafe(t *testing.T) {
	require.NotPanics(t, func() { rewriteAliyunCompatibleAPIRerank(nil) })
}
