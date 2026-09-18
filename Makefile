CHART := charts/scramdb
VALUES_DIR := $(CHART)/ci
KUBECONFORM_ARGS := -strict -summary \
	-schema-location default \
	-schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

.PHONY: all lint test template validate package clean

all: lint test template validate

lint:
	helm lint $(CHART) --strict
	@for f in $(VALUES_DIR)/*-values.yaml; do \
		echo "lint: $$f"; \
		helm lint $(CHART) --values "$$f" --strict || exit 1; \
	done

test:
	helm unittest $(CHART)

template:
	@helm template scramdb $(CHART) > /dev/null && echo "render: defaults"
	@for f in $(VALUES_DIR)/*-values.yaml; do \
		echo "render: $$f"; \
		helm template scramdb $(CHART) --values "$$f" > /dev/null || exit 1; \
	done

# Every rendered object checked against the real Kubernetes schemas, including
# the Prometheus Operator CRDs. Needs kubeconform on PATH.
validate:
	@echo "validate: defaults"
	@helm template scramdb $(CHART) | kubeconform $(KUBECONFORM_ARGS)
	@for f in $(VALUES_DIR)/*-values.yaml; do \
		echo "validate: $$f"; \
		helm template scramdb $(CHART) --values "$$f" | kubeconform $(KUBECONFORM_ARGS) || exit 1; \
	done

package:
	helm package $(CHART) --destination .cr-release-packages

clean:
	rm -rf .cr-release-packages
