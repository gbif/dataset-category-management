#!/bin/bash

# searches for autoMachineTabLabel labels and auto labels with machine-tag

cat config.yaml | shyaml get-values categories | while read cat; do 
    cat="${cat//-/}"
    echo category:"$cat"
    
    cat category-configs/eDNA.yaml | shyaml get-values autoMachineTabLabel | while read label; do
        label="${label//- /}"
        echo " label: $label"
        issues=$(gh issue list --state open --label "$label" --label "$cat" --limit 1000 | awk '{print $1}')
        echo "  issues found: $issues"
        for issue in $issues; do
            echo "  labeling issue $issue with machine-tag"
            gh issue edit "$issue" --add-label "machine-tag" || exit 1
        done
        
    done

done




