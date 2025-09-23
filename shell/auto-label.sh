#!/bin/bash

# searches for autoLabel labels and auto labels with add-category

cat config.yaml | shyaml get-values categories | while read cat; do 
    cat="${cat//-/}"
    echo category:"$cat"
    
    cat category-configs/$cat.yaml | shyaml get-values autoLabel | while read label; do
        label="${label//- /}"
        echo " label: $label"
        issues=$(gh issue list --state open --label "$label" --label "$cat" --limit 1000 | awk '{print $1}')
        echo "  issues found: $issues"
        for issue in $issues; do
            echo "  labeling issue $issue with add-category"
            gh issue edit "$issue" --add-label "add-category" || exit 1
        done
        
    done

done




