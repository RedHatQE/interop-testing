package main

import (
	"fmt"
	"os"
	"time"

	"github.com/spf13/cobra"

	"github.com/RedHatQE/interop-testing/acm-virt/openshift-tests-ext/pkg/adapter"
	"github.com/RedHatQE/interop-testing/acm-virt/openshift-tests-ext/scripts"
	acmvirt "github.com/RedHatQE/interop-testing/acm-virt/openshift-tests-ext/test/acm-virt"
	"github.com/openshift-eng/openshift-tests-extension/pkg/cmd"
	e "github.com/openshift-eng/openshift-tests-extension/pkg/extension"
)

func main() {
	defaultTimeout := 10 * time.Minute
	twoSpokeTimeout := 90 * time.Minute
	upgradeTimeout := 4 * time.Hour

	registry := e.NewRegistry()
	ext := e.NewExtension("acm-virt", "external", "acm-virt-tests-ext")

	// Match the scenario label. tags["component"] keeps only the first tag,
	// so a smoke check shared by more than one topology would otherwise land in one suite.
	ext.AddSuite(e.Suite{
		Name:             "acm-virt/cclm/all",
		Description:      "All ACM+Virt hub-spoke CCLM tests",
		Qualifiers:       []string{`labels.exists(l, l=="acm-virt-cclm")`},
		ClusterStability: e.ClusterStabilityStable,
		Parallelism:      1,
		TestTimeout:      &defaultTimeout,
	})

	ext.AddSuite(e.Suite{
		Name:             "acm-virt/cclm/smoke",
		Description:      "ACM+Virt hub-spoke CCLM smoke tests",
		Qualifiers:       []string{`labels.exists(l, l=="SMOKE") && labels.exists(l, l=="acm-virt-cclm")`},
		ClusterStability: e.ClusterStabilityStable,
		Parallelism:      1,
		TestTimeout:      &defaultTimeout,
	})

	ext.AddSuite(e.Suite{
		Name:             "acm-virt/cclm-2spoke/all",
		Description:      "ACM+Virt two-spoke CCLM forward and return tests",
		Qualifiers:       []string{`labels.exists(l, l=="acm-virt-cclm-2spoke")`},
		ClusterStability: e.ClusterStabilityStable,
		Parallelism:      1,
		TestTimeout:      &twoSpokeTimeout,
	})

	ext.AddSuite(e.Suite{
		Name:             "acm-virt/cnv-upgrade/all",
		Description:      "OpenShift Virtualization upgrade tests",
		Qualifiers:       []string{`labels.exists(l, l=="acm-virt-cnv-upgrade")`},
		ClusterStability: e.ClusterStabilityStable,
		Parallelism:      1,
		TestTimeout:      &upgradeTimeout,
	})

	specs, err := adapter.BuildExtensionTestSpecsFromScenarios(acmvirt.ACMVirtScenarios, scripts.FS)
	if err != nil {
		panic(fmt.Sprintf("couldn't build extension test specs from ACM+Virt CCLM scenarios: %+v", err.Error()))
	}

	ext.AddSpecs(specs)
	registry.Register(ext)

	root := &cobra.Command{
		Use:   "acm-virt-tests-ext",
		Short: "ACM+Virt Tests Extension for OpenShift",
		Long:  "OpenShift Tests Extension (OTE) binary for ACM+Virt hub-spoke CCLM, two-spoke CCLM, and OpenShift Virtualization upgrade testing",
	}

	root.AddCommand(cmd.DefaultExtensionCommands(registry)...)

	if err := root.Execute(); err != nil {
		os.Exit(1)
	}
}
