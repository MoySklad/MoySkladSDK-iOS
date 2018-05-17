//
//  DataManager.swift
//  MoyskladNew
//
//  Created by Anton Efimenko on 02.11.16.
//  Copyright © 2016 Andrey Parshakov. All rights reserved.
//

import Foundation
import RxSwift

/**
 Static data loaded after successful login
*/
public struct LogInInfo {
    ///
    public let employee: MSEmployee
    public let companySettings: MSCompanySettings
    public let states: [MSObjectType: [MSState]]
    public let documentAttributes: [MSObjectType: [MSAttributeDefinition]]
    public let currencies: [String: MSCurrency]
    public let counterpartyTags: [String]
    public let priceTypes: [String]
    public let groups: [String: MSGroup]
    public let createShared: [MSObjectType: Bool]
}

struct MetadataLoadResult {
    let type: MSObjectType
    let states: [MSState]
    let attributes: [MSAttributeDefinition]
    let tags: [String]
    let priceTypes: [String]
    let createShared: Bool
}

public struct DataManager {
    /// Максимальное количество позиций для документа, при большем (при превышении возвращается ошибка)
    static let documentPositionsCountLimit = 100
    
    static func mergeUrlParameters(_ params: UrlParameter?...) -> [UrlParameter] {
        var result = [UrlParameter]()
        params.forEach { p in
            if let p = p {
                result.append(p)
            }
        }
        return result
    }
    
    static func groupBy<T, K: Hashable>(data: [MSEntity<T>], groupingKey: ((T) -> K),
                            withPrevious previousData: [(groupKey: K, data: [MSEntity<T>])]? = nil) -> [(groupKey: K, data: [MSEntity<T>])] {
        var groups: [(groupKey: K, data: [MSEntity<T>])] = previousData ?? []
        
        var lastKroupKey = groups.last?.groupKey
        
        data.map { $0.value() }.removeNils().forEach { object in
            let groupingValue = groupingKey(object)
            if groupingValue == lastKroupKey {
                var lastGroup = groups[groups.count - 1].data
                lastGroup.append(MSEntity.entity(object))
                groups[groups.count - 1] = (groupKey: groupingValue, data: lastGroup)
            } else {
                groups.append((groupKey: groupingValue, data: [MSEntity.entity(object)]))
                lastKroupKey = groupingValue
            }
        }
        
        return groups
    }
    
    static func groupByDate2(data: [MSDocument],
                             withPrevious previousData: [(date: Date, data: [MSDocument])]? = nil) -> [(date: Date, data: [MSDocument])] {
        // объекты группируются по дню (moment)
        var groups: [Date: [MSDocument]] = [:]
        
        // скорее всего это не самый оптимальный способ группировки
        data.forEach { object in
            let moment = object.moment.beginningOfDay()
            var group = groups[moment]
            if group != nil {
                group!.append(object)
                groups[moment] = group
            } else {
                groups[moment] = [object]
            }
        }
        
        previousData?.forEach { prev in
            if let group = groups[prev.date] {
                groups[prev.date] = prev.data + group
            } else {
                groups[prev.date] = prev.data
            }
        }
        
        return groups.map { (date: $0.key, data: $0.value) }.sorted(by: { $0.date > $1.date })
    }
    
    static func groupByDate<T: MSGeneralDocument>(data: [MSEntity<T>], date: ((T) -> Date),
                            withPrevious previousData: [(date: Date, data: [MSEntity<T>])]? = nil) -> [(date: Date, data: [MSEntity<T>])] {
        // объекты группируются по дню (moment)
        var groups: [Date: [MSEntity<T>]] = [:]
        
        // скорее всего это не самый оптимальный способ группировки
        data.compactMap { $0.value() }.forEach { object in
            let moment = date(object).beginningOfDay()
            var group = groups[moment]
            if group != nil {
                group!.append(MSEntity.entity(object))
                groups[moment] = group
            } else {
                groups[moment] = [MSEntity.entity(object)]
            }
        }
        
        previousData?.forEach { prev in
            if let group = groups[prev.date] {
                groups[prev.date] = prev.data + group
            } else {
                groups[prev.date] = prev.data
            }
        }
        
        return groups.map { (date: $0.key, data: $0.value) }.sorted(by: { $0.date > $1.date })
    }
    
    static func deserializeObjectMetadata(objectType: MSObjectType, from json: [String:Any]) -> MetadataLoadResult {
        let metadata = json.msValue(objectType.rawValue)
        let states: [MSState] = metadata.msArray("states").map { MSState.from(dict: $0) }.compactMap { $0?.value() }
        let attrs: [MSAttributeDefinition] = metadata.msArray("attributes").map { MSAttributeDefinition.from(dict: $0) }.compactMap { $0 }
        let priceTypes: [String] = metadata.msArray("priceTypes").map { $0.value("name") }.compactMap { $0 }
        let createShared: Bool = metadata.value("createShared") ?? false
        return MetadataLoadResult(type: objectType, states: states, attributes: attrs, tags: metadata.value("groups") ?? [], priceTypes: priceTypes, createShared: createShared)
    }
    
    static func deserializeArray<T>(json: [String:Any],
                                 incorrectJsonError: Error,
                                 deserializer: @escaping ([String:Any]) -> MSEntity<T>?) -> Observable<[MSEntity<T>]> {
        let deserialized = json.msArray("rows").map { deserializer($0) }
        let withoutNills = deserialized.removeNils()
        
        guard withoutNills.count == deserialized.count else {
            return Observable.error(incorrectJsonError)
        }
        
        return Observable.just(withoutNills)
    }
    
    /**
     Register new account
     - parameter email: Email for new account
     - returns: Registration information
     */
    public static func register(email: String) -> Observable<MSRegistrationResult> {
        return HttpClient.register(email: email).flatMapLatest { result -> Observable<MSRegistrationResult> in
            guard let result = result?.toDictionary() else {
                return  Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectRegistrationResponse.value))
            }
            guard let registration = MSRegistrationResult.from(dict: result) else {
                return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectRegistrationResponse.value))
            }
            return Observable.just(registration)
        }
    }
    
    /**
     Log in
     - parameter auth: Authentication information
     - returns: Login information
    */
    public static func logIn(auth: Auth) -> Observable<LogInInfo> {
        // запрос данных по пользователю и затем настроек компании и статусов документов
        
        let employeeRequest = HttpClient.get(.contextEmployee, auth: auth)
            .flatMapLatest { result -> Observable<MSEmployee> in
                guard let result = result?.toDictionary() else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectLoginResponse.value))
                }
                guard let employee = MSEmployee.from(dict: result)?.value() else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectLoginResponse.value))
                }
                
                return Observable.just(employee)
        }
        
        let settingsRequest = HttpClient.get(.companySettings, auth: auth, urlParameters: [Expander(.currency)])
            .flatMapLatest { result -> Observable<MSCompanySettings> in
                guard let result = result?.toDictionary() else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectCompanySettingsResponse.value))
                }
                guard let settings = MSCompanySettings.from(dict: result)?.value() else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectCompanySettingsResponse.value))
                }
                
                return Observable.just(settings)
        }
        
        let currenciesRequest = HttpClient.get(.currency, auth: auth, urlParameters: [MSOffset(size: 100, limit: 100, offset: 0)])
            .flatMapLatest { result -> Observable<[MSCurrency]> in
                guard let result = result?.toDictionary() else { return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectCurrencyResponse.value)) }
                
                let deserialized = result.msArray("rows").map { MSCurrency.from(dict: $0) }
                
                return Observable.just(deserialized.map { $0?.value() }.removeNils())
            }.catchError { error in
                switch error {
                case MSError.errors(let e):
                    guard let first = e.first, first == MSErrorStruct.accessDenied() else { return Observable.error(error) }
                    return Observable.error(MSError.errors([MSErrorStruct.accessDeniedRate()]))
                default: return Observable.error(error)
                }
        }
        
        let groupsRequest = HttpClient.get(.group, auth: auth, urlParameters: [MSOffset(size: 100, limit: 100, offset: 0)])
            .flatMapLatest { result -> Observable<[MSGroup]> in
                guard let result = result?.toDictionary() else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectGroupResponse.value))
                }
                let deserialized = result.msArray("rows").map { MSGroup.from(dict: $0)?.value() }.removeNils()
                
                return Observable.just(deserialized)
        }
        
        // комбинируем все ответы от запросов и возвращаем LogInInfo
        return Observable.combineLatest(employeeRequest,
                                        settingsRequest,
                                        currenciesRequest,
                                        loadMetadata(auth: auth),
                                        groupsRequest,
                                        resultSelector: {
                                            let states = $3.toDictionary(key: { $0.type }, element: { $0.states })
                                            let attributes = $3.toDictionary(key: { $0.type }, element: { $0.attributes })
                                            let createShared = $3.toDictionary(key: { $0.type }, element: { $0.createShared })
                                            let counterpartyTags = $3.first(where: { $0.type == .counterparty })?.tags ?? []
                                            let assortmentPrices = $3.first(where: { $0.type == .product })?.priceTypes ?? []
                                            
                                            return LogInInfo(employee: $0,
                                                             companySettings: $1,
                                                             states: states,
                                                             documentAttributes: attributes,
                                                             currencies: $2.toDictionary { $0.meta.href.withoutParameters() },
                                                             counterpartyTags: counterpartyTags,
                                                             priceTypes: assortmentPrices,
                                                             groups: $4.toDictionary({ $0.meta.href.withoutParameters() }),
                                                             createShared: createShared)
        })
    }
    
    static func loadMetadata(auth: Auth) -> Observable<[MetadataLoadResult]> {
        return HttpClient.get(.entityMetadata, auth: auth, urlParameters: [MSOffset(size: 0, limit: 100, offset: 0)])
            .flatMapLatest { result -> Observable<[MetadataLoadResult]> in
                guard let json = result?.toDictionary() else { return.just([]) }
                let metadata: [MetadataLoadResult] = [deserializeObjectMetadata(objectType: .customerorder, from: json),
                                                      deserializeObjectMetadata(objectType: .demand, from: json),
                                                      deserializeObjectMetadata(objectType: .invoicein, from: json),
                                                      deserializeObjectMetadata(objectType: .cashin, from: json),
                                                      deserializeObjectMetadata(objectType: .cashout, from: json),
                                                      deserializeObjectMetadata(objectType: .paymentin, from: json),
                                                      deserializeObjectMetadata(objectType: .paymentout, from: json),
                                                      deserializeObjectMetadata(objectType: .supply, from: json),
                                                      deserializeObjectMetadata(objectType: .invoicein, from: json),
                                                      deserializeObjectMetadata(objectType: .invoiceout, from: json),
                                                      deserializeObjectMetadata(objectType: .purchaseorder, from: json),
                                                      deserializeObjectMetadata(objectType: .counterparty, from: json),
                                                      deserializeObjectMetadata(objectType: .move, from: json),
                                                      deserializeObjectMetadata(objectType: .inventory, from: json),
                                                      deserializeObjectMetadata(objectType: .product, from: json)]
                return .just(metadata)
        }
    }
    
    /**
     Load dashboard data for current day
     - parameter auth: Authentication information
     - returns: Dashboard
    */
    public static func dashboardDay(auth: Auth) -> Observable<MSDashboard> {
        return HttpClient.get(.dashboardDay, auth: auth)
            .flatMapLatest { result -> Observable<MSDashboard> in
                guard let result = result?.toDictionary() else { return Observable.empty() }
                guard let dash = MSDashboard.from(dict: result) else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectDashboardResponse.value))
                }
                return Observable.just(dash)
        }
    }
    
    /**
     Load dashboard data for current week
     - parameter auth: Authentication information
     - returns: Dashboard
     */
    public static func dashboardWeek(auth: Auth) -> Observable<MSDashboard> {
        return HttpClient.get(.dashboardWeek, auth: auth)
            .flatMapLatest { result -> Observable<MSDashboard> in
                guard let result = result?.toDictionary() else { return Observable.empty() }
                guard let dash = MSDashboard.from(dict: result) else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectDashboardResponse.value))
                }
                return Observable.just(dash)
        }
    }
    
    /**
     Load dashboard data for current month
     - parameter auth: Authentication information
     - returns: Dashboard
     */
    public static func dashboardMonth(auth: Auth) -> Observable<MSDashboard> {
        return HttpClient.get(.dashboardMonth, auth: auth)
            .flatMapLatest { result -> Observable<MSDashboard> in
                guard let result = result?.toDictionary() else { return Observable.empty() }
                guard let dash = MSDashboard.from(dict: result) else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectDashboardResponse.value))
                }
                return Observable.just(dash)
        }
    }
    
    /**
     Load Assortment.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#ассортимент)
     - parameter auth: Authentication information
     - parameter offset: Desired data offset
     - parameter expanders: Additional objects to include into request
     - parameter filter: Filter for request
     - parameter search: Additional string for filtering by name
     - parameter stockStore: Specifies specific Store for filtering
     - parameter scope: Filter data for scope. For example if product specified, query will not return variants for product
     - returns: Collection of Assortment
    */
    public static func assortment(auth: Auth,
                                  offset: MSOffset? = nil, 
                                  expanders: [Expander] = [], 
                                  filter: Filter? = nil,
                                  search: Search? = nil, 
                                  stockStore: StockStore? = nil, 
                                  scope: AssortmentScope? = nil)
        -> Observable<[MSEntity<MSAssortment>]> {
            
            let urlParameters: [UrlParameter] = mergeUrlParameters(offset, filter, search, stockStore, scope, CompositeExpander(expanders), StockMomentAssortment(value: Date()))
            
            return HttpClient.get(.assortment, auth: auth, urlParameters: urlParameters)
            .flatMapLatest { result -> Observable<[MSEntity<MSAssortment>]> in
                guard let result = result?.toDictionary() else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectAssortmentResponse.value))
                }
                
                let deserialized = result.msArray("rows").map { MSAssortment.from(dict: $0) }
                let withoutNills = deserialized.removeNils()
                
                guard withoutNills.count == deserialized.count else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectAssortmentResponse.value))
                }
                
                return Observable.just(withoutNills)
            }
    }
    
    /**
     Load organizations.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#юрлицо)
     - parameter offset: Desired data offset
     - parameter expanders: Additional objects to include into request
     - parameter filter: Filter for request
     - parameter search: Additional string for filtering by name
    */
    public static func organizations(auth: Auth,
                                     offset: MSOffset? = nil, 
                                     expanders: [Expander] = [], 
                                     filter: Filter? = nil, 
                                     search: Search? = nil)
        -> Observable<[MSEntity<MSAgent>]> {
            let urlParameters: [UrlParameter] = mergeUrlParameters(offset, filter, search, CompositeExpander(expanders))
            return HttpClient.get(.organization, auth: auth, urlParameters: urlParameters)
                .flatMapLatest { result -> Observable<[MSEntity<MSAgent>]> in
                    guard let result = result?.toDictionary() else {
                        return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectOrganizationResponse.value))
                    }
                    
                    let deserialized = result.msArray("rows").map { MSAgent.from(dict: $0) }
                    let withoutNills = deserialized.removeNils()
                    
                    guard withoutNills.count == deserialized.count else {
                        return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectOrganizationResponse.value))
                    }
                    
                    return Observable.just(withoutNills)
            }
    }
    
    /**
     Load counterparties.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#контрагент)
     - parameter offset: Desired data offset
     - parameter expanders: Additional objects to include into request
     - parameter filter: Filter for request
     - parameter search: Additional string for filtering by name
     */
    public static func counterparties(auth: Auth,
                                      offset: MSOffset? = nil, 
                                      expanders: [Expander] = [], 
                                      filter: Filter? = nil, 
                                      search: Search? = nil)
        -> Observable<[MSEntity<MSAgent>]> {
            let urlParameters: [UrlParameter] = mergeUrlParameters(offset, search, CompositeExpander(expanders), filter)
            
            return HttpClient.get(.counterparty, auth: auth, urlParameters: urlParameters)
                .flatMapLatest { result -> Observable<[MSEntity<MSAgent>]> in
                    guard let result = result?.toDictionary() else { return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectCounterpartyResponse.value)) }
                    
                    return deserializeArray(json: result,
                                            incorrectJsonError: MSError.genericError(errorText: LocalizedStrings.incorrectCounterpartyResponse.value),
                                            deserializer: { MSAgent.from(dict: $0) })
            }
    }
    
    /**
     Load counterparties with report.
     Also see API reference [ for counterparties](https://online.moysklad.ru/api/remap/1.1/doc/index.html#контрагент) and [ counterparty reports](https://online.moysklad.ru/api/remap/1.1/doc/index.html#отчёт-показатели-контрагентов-показатели-контрагентов)
     - parameter offset: Desired data offset
     - parameter expanders: Additional objects to include into request
     - parameter filter: Filter for request
     - parameter search: Additional string for filtering by name
     */
    public static func counterpartiesWithReport(auth: Auth,
                                      offset: MSOffset? = nil,
                                      expanders: [Expander] = [],
                                      filter: Filter? = nil,
                                      search: Search? = nil)
        -> Observable<[MSEntity<MSAgent>]> {
            let urlParameters: [UrlParameter] = mergeUrlParameters(offset, search, CompositeExpander(expanders), filter)
            
            return HttpClient.get(.counterparty, auth: auth, urlParameters: urlParameters)
                .flatMapLatest { result -> Observable<[MSEntity<MSAgent>]> in
                    guard let result = result?.toDictionary() else { return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectCounterpartyResponse.value)) }
                    
                    return deserializeArray(json: result,
                                            incorrectJsonError: MSError.genericError(errorText: LocalizedStrings.incorrectCounterpartyResponse.value),
                                            deserializer: { MSAgent.from(dict: $0) })
            }
                .flatMapLatest { counterparties -> Observable<[MSEntity<MSAgent>]> in
                    return loadReportsForCounterparties(auth: auth, counterparties: counterparties)
                        .catchError { e in
                            guard MSError.isCrmAccessDenied(from: e) else { throw e }
                            
                            return .just([])
                        }
                        .flatMapLatest { reports -> Observable<[MSEntity<MSAgent>]> in
                            let new = counterparties.toDictionary({ $0.objectMeta().objectId })
                            reports.forEach {
                                new[$0.value()?.agent.objectMeta().objectId ?? ""]?.value()?.report = $0
                            }
                            return .just(Array(new.values))
                    }
            }
    }
    
    /**
     Load Assortment and group result by product folder
     - parameter auth: Authentication information
     - parameter offset: Desired data offset
     - parameter expanders: Additional objects to include into request
     - parameter filter: Filter for request
     - parameter search: Additional string for filtering by name
     - parameter stockStore: Specifies specific Store for filtering
     - parameter scope: Filter data for scope. For example if product specified, query will not return variants for product
     - parameter withPrevious: Grouped data returned by previous invocation of assortmentGroupedByProductFolder (useful for paged loading)
     - returns: Collection of grouped Assortment
     */
    public static func assortmentGroupedByProductFolder(auth: Auth, 
                                                        offset: MSOffset? = nil, 
                                                        expanders: [Expander] = [],
                                                        filter: Filter? = nil, 
                                                        search: Search? = nil, 
                                                        stockStore: StockStore? = nil,
                                                        scope: AssortmentScope? = nil,
                                                        withPrevious: [(groupKey: String, data: [MSEntity<MSAssortment>])]? = nil)
        -> Observable<[(groupKey: String, data: [MSEntity<MSAssortment>])]> {
            return assortment(auth: auth, offset: offset, expanders: expanders, filter: filter, search: search, stockStore: stockStore, scope: scope)
                .flatMapLatest { result -> Observable<[(groupKey: String, data: [MSEntity<MSAssortment>])]> in
                    
                    let grouped = DataManager.groupBy(data: result, groupingKey: { $0.getFolderName() ?? "" }, withPrevious: withPrevious)
                    
                    return Observable.just(grouped)
            }
    }
    
    /**
     Load stock data.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#отчёт-остатки-все-остатки-get)
     - parameter auth: Authentication information
     - parameter assortments: Collection of assortments. If specified, stock data will be returned only for this assortment objects
     - parameter store: Stock data will be returned for specific Store, if specified
     - parameter stockMode: Mode for stock data
     - parameter moment: The time point for stock data
    */
    public static func productStockAll(auth: Auth,
                                       assortments: [MSEntity<MSAssortment>], 
                                       store: MSStore? = nil, 
                                       stockMode: StockMode = .all,
                                       moment: Date? = nil) -> Observable<[MSEntity<MSProductStockAll>]> {
        var parameters: [UrlParameter] = assortments.map { StockProductId(value: $0.objectMeta().objectId) }
        
        if let storeId = store?.id.msID?.uuidString {
            parameters.append(StockStoretId(value: storeId))
        }
        
        if let moment = moment {
            parameters.append(StockMoment(value: moment))
        }
        
        parameters.append(stockMode)
        parameters.append(MSOffset(size: 100, limit: 100, offset: 0))
        
        return HttpClient.get(.stockAll, auth: auth, urlParameters: parameters)
            .flatMapLatest { result -> Observable<[MSEntity<MSProductStockAll>]> in
            guard let result = result?.toDictionary() else {
                return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectStockAllResponse.value))
                }
            
            let array = result.msArray("rows")
            guard array.count > 0 else {
                // если массив пустой, значит остатков нет
                return Observable.just([])
            }
            
            let deserialized = array.map { MSProductStockAll.from(dict: $0) }.removeNils()
            
            return Observable.just(deserialized)
        }
    }
    
    /**
     Load stock distributed by stores.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#отчёт-остатки-все-остатки-get)
     - parameter auth: Authentication information
     - parameter assortment: Assortment for whick stock data should be loaded
    */
    public static func productStockByStore(auth: Auth, assortment: MSAssortment) -> Observable<[MSEntity<MSProductStockStore>]> {
        let parameters: [UrlParameter] = [MSOffset(size: 100, limit: 100, offset: 0),
                                          StockProductId(value: assortment.id.msID?.uuidString ?? "")]
        return HttpClient.get(.stockByStore, auth: auth, urlParameters: parameters)
            .flatMapLatest { result -> Observable<[MSEntity<MSProductStockStore>]> in
            guard let result = result?.toDictionary() else {
                return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectStockByStoreResponse.value))
                }
            
            guard let array = result.msArray("rows").first?.msArray("stockByStore"),
                array.count > 0 else {
                    // если массив пустой, значит остатков нет
                    // возвращаем пустой массив
                    return Observable.just([])
            }
            
            let deserialized = array.map { MSProductStockStore.from(dict: $0) }
            let withoutNills = deserialized.removeNils()
            
            guard withoutNills.count == deserialized.count else {
                return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectStockByStoreResponse.value))
            }
            
            return Observable.just(withoutNills)
        }
    }
    
    /**
     Returns combined data from productStockAll and productStockByStore requests
     - parameter auth: Authentication information
     - parameter assortment: Assortment for whick stock data should be loaded
    */
    public static func productCombinedStock(auth: Auth, assortment: MSAssortment) -> Observable<(all: MSProductStockAll, store: [MSProductStockStore])?> {
        return productStockAll(auth: auth, assortments: [MSEntity.entity(assortment)]).flatMapLatest { allStock -> Observable<(all: MSProductStockAll, store: [MSProductStockStore])?> in
            let prodStockAll: MSProductStockAll? = {
                guard let allStock = allStock.first else {
                    // если остатки не пришли вообще, значит там пусто, возвращаем пустую структуру
                    return MSProductStockAll.empty()
                }
                
                return allStock.value()
            }()
            
            guard let all = prodStockAll else {
                return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectStockAllResponse.value))
            }
            
            return productStockByStore(auth: auth, assortment: assortment)
                .flatMapLatest { byStore -> Observable<(all: MSProductStockAll, store: [MSProductStockStore])?> in
                let withoutNils = byStore.map { $0.value() }.removeNils()
                
                guard withoutNils.count == byStore.count else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectStockAllResponse.value))
                    }
                
                return Observable.just((all: all, store: withoutNils))
            }
        }
    }
    
    /**
     Load Product folders.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#группа-товаров)
     - parameter auth: Authentication information
     - parameter offset: Desired data offset
     - parameter expanders: Additional objects to include into request
     - parameter filter: Filter for request
     - parameter search: Additional string for filtering by name
    */
    public static func productFolders(auth: Auth,
                                      offset: MSOffset? = nil,
                                      expanders: [Expander] = [],
                                      filter: Filter? = nil,
                                      search: Search? = nil) -> Observable<[MSEntity<MSProductFolder>]> {
        let urlParameters: [UrlParameter] = mergeUrlParameters(offset, filter, search, CompositeExpander(expanders))
        
        return HttpClient.get(.productFolder, auth: auth, urlParameters: urlParameters)
            .flatMapLatest { result -> Observable<[MSEntity<MSProductFolder>]> in
                
                guard let result = result?.toDictionary() else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectProductFolderResponse.value))
                }
                
                let deserialized = result.msArray("rows").map { MSProductFolder.from(dict: $0) }
                let withoutNills = deserialized.removeNils()
                
                guard withoutNills.count == deserialized.count else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectProductFolderResponse.value))
                }
                
                return Observable.just(withoutNills)
        }
    }
    
    /**
     Load stores.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#склад)
     - parameter auth: Authentication information
     - parameter offset: Desired data offset
     - parameter expanders: Additional objects to include into request
     - parameter filter: Filter for request
     - parameter search: Additional string for filtering by name
    */
    public static func stores(auth: Auth,
                              offset: MSOffset? = nil,
                              expanders: [Expander] = [],
                              filter: Filter? = nil, 
                              search: Search? = nil) -> Observable<[MSEntity<MSStore>]> {
        let urlParameters: [UrlParameter] = mergeUrlParameters(offset, filter, search, CompositeExpander(expanders))
        
        return HttpClient.get(.store, auth: auth, urlParameters: urlParameters)
            .flatMapLatest { result -> Observable<[MSEntity<MSStore>]> in
                
                guard let result = result?.toDictionary() else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectStoreResponse.value))
                }
                
                let deserialized = result.msArray("rows").map { MSStore.from(dict: $0) }
                let withoutNills = deserialized.removeNils()
                
                guard withoutNills.count == deserialized.count else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectStoreResponse.value))
                }
                
                return Observable.just(withoutNills)
        }
    }
    
    /**
     Load projects.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#проект)
     - parameter auth: Authentication information
     - parameter offset: Desired data offset
     - parameter expanders: Additional objects to include into request
     - parameter filter: Filter for request
     - parameter search: Additional string for filtering by name
    */
    public static func projects(auth: Auth,
                                offset: MSOffset? = nil, 
                                expanders: [Expander] = [],
                                filter: Filter? = nil, 
                                search: Search? = nil) -> Observable<[MSEntity<MSProject>]> {
        let urlParameters: [UrlParameter] = mergeUrlParameters(offset, search, filter, CompositeExpander(expanders))
        
        return HttpClient.get(.project, auth: auth, urlParameters: urlParameters)
            .flatMapLatest { result -> Observable<[MSEntity<MSProject>]> in
                guard let result = result?.toDictionary() else { return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectProjectResponse.value)) }
                
                return deserializeArray(json: result,
                                 incorrectJsonError: MSError.genericError(errorText: LocalizedStrings.incorrectProjectResponse.value),
                                 deserializer: { MSProject.from(dict: $0) })
        }
    }
    
    /**
     Load groups.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#отдел)
     - parameter auth: Authentication information
     - parameter offset: Desired data offset
     - parameter expanders: Additional objects to include into request
     - parameter filter: Filter for request
     - parameter search: Additional string for filtering by name
    */
    public static func groups(auth: Auth,
                              offset: MSOffset? = nil, 
                              expanders: [Expander] = [], 
                              filter: Filter? = nil, 
                              search: Search? = nil)
        -> Observable<[MSEntity<MSGroup>]> {
        let urlParameters: [UrlParameter] = mergeUrlParameters(offset, filter, search, CompositeExpander(expanders))
        
        return HttpClient.get(.group, auth: auth, urlParameters: urlParameters)
            .flatMapLatest { result -> Observable<[MSEntity<MSGroup>]> in
                guard let result = result?.toDictionary() else { return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectGroupResponse.value)) }
                
                return deserializeArray(json: result,
                                        incorrectJsonError: MSError.genericError(errorText: LocalizedStrings.incorrectGroupResponse.value),
                                        deserializer: { MSGroup.from(dict: $0) })
        }
    }
    
    /**
     Load currencies.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#валюта)
     - parameter auth: Authentication information
     - parameter offset: Desired data offset
     - parameter expanders: Additional objects to include into request
     - parameter filter: Filter for request
     - parameter search: Additional string for filtering by name
    */
    public static func currencies(auth: Auth,
                                  offset: MSOffset? = nil,
                                  expanders: [Expander] = [],
                                  filter: Filter? = nil,
                                  search: Search? = nil) -> Observable<[MSEntity<MSCurrency>]> {
        let urlParameters: [UrlParameter] = mergeUrlParameters(offset, search, CompositeExpander(expanders), filter)
        
        return HttpClient.get(.currency, auth: auth, urlParameters: urlParameters)
            .flatMapLatest { result -> Observable<[MSEntity<MSCurrency>]> in
                guard let result = result?.toDictionary() else { return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectCurrencyResponse.value)) }
                
                return deserializeArray(json: result,
                                        incorrectJsonError: MSError.genericError(errorText: LocalizedStrings.incorrectCurrencyResponse.value),
                                        deserializer: { MSCurrency.from(dict: $0) })
        }
    }
    
    /**
     Load contracts.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#договор)
     - parameter auth: Authentication information
     - parameter offset: Desired data offset
     - parameter expanders: Additional objects to include into request
     - parameter filter: Filter for request
     - parameter search: Additional string for filtering by name
     */
    public static func contracts(auth: Auth,
                                 offset: MSOffset? = nil, 
                                 expanders: [Expander] = [],
                                 filter: Filter? = nil,
                                 search: Search? = nil) -> Observable<[MSEntity<MSContract>]> {
        let urlParameters: [UrlParameter] = mergeUrlParameters(offset, search, CompositeExpander(expanders), filter)
        
        return HttpClient.get(.contract, auth: auth, urlParameters: urlParameters)
            .flatMapLatest { result -> Observable<[MSEntity<MSContract>]> in
                guard let result = result?.toDictionary() else { return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectContractResponse.value)) }
                
                return deserializeArray(json: result,
                                        incorrectJsonError: MSError.genericError(errorText: LocalizedStrings.incorrectContractResponse.value),
                                        deserializer: { MSContract.from(dict: $0) })
        }
    }
    
    /**
     Load employees.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#сотрудник)
     - parameter auth: Authentication information
     - parameter offset: Desired data offset
     - parameter expanders: Additional objects to include into request
     - parameter filter: Filter for request
     - parameter search: Additional string for filtering by name
     */
    public static func employees(auth: Auth, 
                                 offset: MSOffset? = nil, 
                                 expanders: [Expander] = [], 
                                 filter: Filter? = nil, 
                                 search: Search? = nil) -> Observable<[MSEntity<MSEmployee>]> {
        let urlParameters: [UrlParameter] = mergeUrlParameters(offset, search, CompositeExpander(expanders), filter)
        
        return HttpClient.get(.employee, auth: auth, urlParameters: urlParameters)
            .flatMapLatest { result -> Observable<[MSEntity<MSEmployee>]> in
                guard let result = result?.toDictionary() else { return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectEmployeeResponse.value)) }
                
                return deserializeArray(json: result,
                                        incorrectJsonError: MSError.genericError(errorText: LocalizedStrings.incorrectEmployeeResponse.value),
                                        deserializer: { MSEmployee.from(dict: $0) })
        }
    }
    
    /**
     Load employees to agent
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#сотрудник)
     - parameter auth: Authentication information
     - parameter offset: Desired data offset
     - parameter expanders: Additional objects to include into request
     - parameter filter: Filter for request
     - parameter search: Additional string for filtering by name
     
     Реализовано для возможности совмещать на одном экране контрагентов и сотрудников. Релизовано на экране выбора контрагента
     */
    public static func employeesForAgents(auth: Auth,
                                 offset: MSOffset? = nil,
                                 expanders: [Expander] = [],
                                 filter: Filter? = nil,
                                 search: Search? = nil) -> Observable<[MSEntity<MSAgent>]> {
        let urlParameters: [UrlParameter] = mergeUrlParameters(offset, search, CompositeExpander(expanders), filter)
        
        return HttpClient.get(.employee, auth: auth, urlParameters: urlParameters)
            .flatMapLatest { result -> Observable<[MSEntity<MSAgent>]> in
                guard let result = result?.toDictionary() else { return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectEmployeeResponse.value)) }
                
                return deserializeArray(json: result,
                                        incorrectJsonError: MSError.genericError(errorText: LocalizedStrings.incorrectEmployeeResponse.value),
                                        deserializer: { MSAgent.from(dict: $0) })
        }
    }
    
    /**
     Load accounts for specified agent.
     Also see API reference for [ counterparty](https://online.moysklad.ru/api/remap/1.1/doc/index.html#контрагент-счета-контрагента-get)
     and [ organizaiton](https://online.moysklad.ru/api/remap/1.1/doc/index.html#юрлицо-счета-юрлица-get)
     - parameter agent: Agent for which accounts will be loaded
     - parameter auth: Authentication information
     - parameter offset: Desired data offset
     - parameter expanders: Additional objects to include into request
     - parameter filter: Filter for request
     - parameter search: Additional string for filtering by name
     */
    public static func agentAccounts(agent: MSAgent,
                                     auth: Auth,
                                     offset: MSOffset? = nil, 
                                     expanders: [Expander] = [], 
                                     filter: Filter? = nil, 
                                     search: Search? = nil) -> Observable<[MSEntity<MSAccount>]> {
        let urlParameters: [UrlParameter] = mergeUrlParameters(offset, search, CompositeExpander(expanders), filter)
        
        let pathComponents = [agent.id.msID?.uuidString ?? "", "accounts"]
        
        let request: Observable<JSONType?> = {
            switch agent.meta.type {
            case MSObjectType.counterparty: return HttpClient.get(.counterparty, auth: auth,
                                                                  urlPathComponents: pathComponents, urlParameters: urlParameters)
            case MSObjectType.organization: return HttpClient.get(.organization, auth: auth,
                                                                  urlPathComponents: pathComponents, urlParameters: urlParameters)
            default: return Observable.empty() // MSAgent бывает только двух типов
            }
        }()
        
        return request.flatMapLatest { result -> Observable<[MSEntity<MSAccount>]> in
                guard let result = result?.toDictionary() else { return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectEmployeeResponse.value)) }
                
                return deserializeArray(json: result,
                                        incorrectJsonError: MSError.genericError(errorText: LocalizedStrings.incorrectEmployeeResponse.value),
                                        deserializer: { MSAccount.from(dict: $0) })
        }
    }
    
    /**
     Load product info by product id
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#товар-товар-get)
     - parameter auth: Authentication information
     - parameter id: Product id
     - parameter expanders: Additional objects to include into request
    */
    public static func productAssortmentById(auth: Auth,
                                             id : UUID,
                                             expanders: [Expander] = []) -> Observable<MSEntity<MSAssortment>> {
        return HttpClient.get(.product, auth: auth, urlPathComponents: [id.uuidString], urlParameters: [CompositeExpander(expanders)])
            .flatMapLatest { result -> Observable<MSEntity<MSAssortment>> in
                guard let result = result?.toDictionary() else { return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectProductResponse.value)) }
                
                guard let deserialized = MSAssortment.from(dict: result) else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectProductResponse.value))
                }
                
                return Observable.just(deserialized)
        }
    }
    
    /**
     Load product info by bundle id.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#комплект-комплект-get)
     - parameter auth: Authentication information
     - parameter id: Bundle id
     - parameter expanders: Additional objects to include into request
     */
    public static func bundleAssortmentById(auth: Auth, id : UUID, expanders: [Expander] = []) -> Observable<MSEntity<MSAssortment>> {
        return HttpClient.get(.bundle, auth: auth, urlPathComponents: [id.uuidString], urlParameters: [CompositeExpander(expanders)])
            .flatMapLatest { result -> Observable<MSEntity<MSAssortment>> in
                guard let result = result?.toDictionary() else { return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectBundleResponse.value)) }
                
                guard let deserialized = MSAssortment.from(dict: result) else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectBundleResponse.value))
                }
                
                return Observable.just(deserialized)
        }
    }
    
    /**
     Load product info by variant id.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#модификация-модификация-get)
     - parameter auth: Authentication information
     - parameter id: Variant id
     - parameter expanders: Additional objects to include into request
     */
    public static func variantAssortmentById(auth: Auth, id : UUID, expanders: [Expander] = []) -> Observable<MSEntity<MSAssortment>> {
        return HttpClient.get(.variant, auth: auth, urlPathComponents: [id.uuidString], urlParameters: [CompositeExpander(expanders)])
            .flatMapLatest { result -> Observable<MSEntity<MSAssortment>> in
                guard let result = result?.toDictionary() else { return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectVariantResponse.value)) }
                
                guard let deserialized = MSAssortment.from(dict: result) else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectVariantResponse.value))
                }
                
                return Observable.just(deserialized)
        }
    }
    
    /**
     Load custom entities
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#пользовательский-справочник)
     - parameter auth: Authentication information
     - parameter metadataId: Id of custom entity
     - parameter offset: Desired data offset
     - parameter search: Additional string for filtering by name
    */
    public static func customEntities(auth: Auth,
                                      metadataId: String, 
                                      offset: MSOffset? = nil, 
                                      search: Search? = nil) -> Observable<[MSEntity<MSCustomEntity>]> {
        let urlParameters: [UrlParameter] = mergeUrlParameters(offset, search)
        
        return HttpClient.get(.customEntity, auth: auth, urlPathComponents: [metadataId], urlParameters: urlParameters)
            .flatMapLatest { result -> Observable<[MSEntity<MSCustomEntity>]> in
                guard let result = result?.toDictionary() else { return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectCustomEntityResponse.value)) }
                
                return deserializeArray(json: result,
                                        incorrectJsonError: MSError.genericError(errorText: LocalizedStrings.incorrectCustomEntityResponse.value),
                                        deserializer: { MSCustomEntity.from(dict: $0) })
        }
    }
    
    /**
     Load product info by service id.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#услуга-услуга-get)
     - parameter auth: Authentication information
     - parameter id: Service id
     - parameter expanders: Additional objects to include into request
     */
    public static func serviceAssortmentById(auth: Auth, 
                                             id : UUID, 
                                             expanders: [Expander] = []) -> Observable<MSEntity<MSAssortment>> {
        return HttpClient.get(.service, auth: auth, urlPathComponents: [id.uuidString], urlParameters: [CompositeExpander(expanders)])
            .flatMapLatest { result -> Observable<MSEntity<MSAssortment>> in
                guard let result = result?.toDictionary() else { return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectServiceResponse.value)) }
                
                guard let deserialized = MSAssortment.from(dict: result) else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectServiceResponse.value))
                }
                
                return Observable.just(deserialized)
        }
    }
    
    /**
     Load SalesByProduct report for current day.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#отчёт-прибыльность-прибыльность-по-товарам-get)
     - parameter auth: Authentication information
     - parameter offset: Desired data offset
    */
    public static func salesByProductDay(auth: Auth, offset: MSOffset? = nil) -> Observable<[MSSaleByProduct]> {
        return salesByProduct(auth: auth, from: Date().beginningOfDay(), to: Date().endOfDay(), offset: offset)
    }
    
    /**
     Load SalesByProduct report for current week.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#отчёт-прибыльность-прибыльность-по-товарам-get)
     - parameter auth: Authentication information
     - parameter offset: Desired data offset
     */
    public static func salesByProductWeek(auth: Auth, offset: MSOffset? = nil) -> Observable<[MSSaleByProduct]> {
        return salesByProduct(auth: auth, from: Date().startOfWeek(), to: Date().endOfWeek(), offset: offset)
    }
    
    /**
     Load SalesByProduct report for current month.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#отчёт-прибыльность-прибыльность-по-товарам-get)
     - parameter auth: Authentication information
     - parameter offset: Desired data offset
     */
    public static func salesByProductMonth(auth: Auth, offset: MSOffset? = nil) -> Observable<[MSSaleByProduct]> {
        return salesByProduct(auth: auth, from: Date().startOfMonth(), to: Date().endOfMonth(), offset: offset)
    }
    
    /**
     Load SalesByProduct report.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#отчёт-прибыльность-прибыльность-по-товарам-get)
     - parameter auth: Authentication information
     - parameter from: Start date for report
     - parameter to: End date for report
     - parameter offset: Desired data offset
    */
    public static func salesByProduct(auth: Auth,
                                      from: Date, 
                                      to: Date, 
                                      offset: MSOffset? = nil) -> Observable<[MSSaleByProduct]> {
        let momentFrom = GenericUrlParameter(name: "momentFrom", value: from.toCurrentLocaleLongDate())
        let momentTo = GenericUrlParameter(name: "momentTo", value: to.toCurrentLocaleLongDate())
        
        let urlParameters: [UrlParameter] = mergeUrlParameters(offset, momentFrom, momentTo)
        
        return HttpClient.get(.salesByProduct, auth: auth, urlParameters: urlParameters).flatMapLatest { result -> Observable<[MSSaleByProduct]> in
            
            guard let result = result?.toDictionary() else {
                return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectSalesByProductResponse.value))
            }
            
            let deserialized = result.msArray("rows").map { MSSaleByProduct.from(dict: $0) }
            let withoutNills = deserialized.removeNils()
            
            guard withoutNills.count == deserialized.count else {
                return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectSalesByProductResponse.value))
            }
            
            return Observable.just(withoutNills)
        }
    }
    
        
    /**
     Load counterparty contacts.
     Also see [ API refere`nce](https://online.moysklad.ru/api/remap/1.1/doc#контрагент-контактное-лицо-get)
     - parameter auth: Authentication information
     - parameter id: Id of counterparty
     - returns: Observable sequence with contacts
     */
    public static func counterpartyContacts(auth: Auth, id: String) -> Observable<[MSEntity<MSContactPerson>]> {
        let urlPathComponents: [String] = [id, "contactpersons"]
        return HttpClient.get(.counterparty, auth: auth, urlPathComponents: urlPathComponents, urlParameters: [])
            .flatMapLatest { result -> Observable<[MSEntity<MSContactPerson>]> in
                guard let results = result?.toDictionary()?.msArray("rows") else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrecContactPersonsResponse.value))
                }
                
                return Observable.just(results.flatMap({ (contact) -> MSEntity<MSContactPerson>? in
                    return MSContactPerson.from(dict: contact)
                }))
        }
    }
    
    /**
     Searches counterparty data by INN.
     - parameter auth: Authentication information
     - parameter id: INN of counterparty
     - returns: Observable sequence with counterparty info
     */
    public static func searchCounterpartyByInn(auth: Auth, inn: String) -> Observable<[MSCounterpartySearchResult]> {
        return HttpClient.get(.suggestCounterparty, auth: auth, urlParameters: [GenericUrlParameter(name: "search", value: inn)])
            .flatMapLatest { result -> Observable<[MSCounterpartySearchResult]> in
                guard let results = result?.toDictionary()?.msArray("rows") else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectCounterpartySearchResponse.value))
                }
                
                return Observable.just(results.map { MSCounterpartySearchResult.from(dict: $0) }.removeNils())
        }
    }
    
    /**
     Searches bank data by BIC.
     - parameter auth: Authentication information
     - parameter id: BIC
     - returns: Observable sequence with bank info
     */
    public static func searchBankByBic(auth: Auth, bic: String) -> Observable<[MSBankSearchResult]> {
        return HttpClient.get(.suggestBank, auth: auth, urlParameters: [GenericUrlParameter(name: "search", value: bic)])
            .flatMapLatest { result -> Observable<[MSBankSearchResult]> in
                guard let results = result?.toDictionary()?.msArray("rows") else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectBankSearchResponse.value))
                }
                
                return Observable.just(results.map { MSBankSearchResult.from(dict: $0) })
        }
    }
    
    /**
     Load tasks.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#задача)
     - parameter auth: Authentication information
     - parameter offset: Desired data offset
     - parameter expanders: Additional objects to include into request
     - parameter filter: Filter for request
     - parameter search: Additional string for filtering by name
     */
    public static func tasks(auth: Auth,
                                 offset: MSOffset? = nil,
                                 expanders: [Expander] = [],
                                 filter: Filter? = nil,
                                 search: Search? = nil,
                                 orderBy: Order? = nil) -> Observable<[MSEntity<MSTask>]> {
        let urlParameters: [UrlParameter] = mergeUrlParameters(offset, search, CompositeExpander(expanders), filter, orderBy)
        
        return HttpClient.get(.task, auth: auth, urlParameters: urlParameters)
            .flatMapLatest { result -> Observable<[MSEntity<MSTask>]> in
                guard let result = result?.toDictionary() else { return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectTasksResponse.value)) }
                
                return deserializeArray(json: result,
                                        incorrectJsonError: MSError.genericError(errorText: LocalizedStrings.incorrectEmployeeResponse.value),
                                        deserializer: { MSTask.from(dict: $0) })
        }
    }
    
    /**
     Load task by id.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#задача)
     - parameter auth: Authentication information
     - parameter offset: Desired data offset
     - parameter expanders: Additional objects to include into request
     - parameter filter: Filter for request
     - parameter search: Additional string for filtering by name
     */
    public static func loadById(auth: Auth,
                             taskId: UUID,
                             expanders: [Expander] = [],
                             filter: Filter? = nil,
                             search: Search? = nil) -> Observable<MSEntity<MSTask>> {
        let urlParameters: [UrlParameter] = mergeUrlParameters(search, CompositeExpander(expanders), filter)
        
        return HttpClient.get(.task, auth: auth, urlPathComponents: [taskId.uuidString], urlParameters: urlParameters)
            .flatMapLatest { result -> Observable<MSEntity<MSTask>> in

                guard let result = result?.toDictionary() else { return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectTasksResponse.value)) }
                
                guard let deserialized = MSTask.from(dict: result) else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectTasksResponse.value))
                }
                
                return Observable.just(deserialized)
        }
    }
    
    public static func loadExpenseitems(auth: Auth,
                                        offset: MSOffset? = nil,
                                        expanders: [Expander] = [],
                                        filter: Filter? = nil,
                                        search: Search? = nil) -> Observable<[MSEntity<MSExpenseItem>]> {
        let urlParameters: [UrlParameter] = mergeUrlParameters(offset, filter, search, CompositeExpander(expanders))
        return HttpClient.get(.expenseitem, auth: auth, urlParameters: urlParameters)
            .flatMapLatest { result -> Observable<[MSEntity<MSExpenseItem>]> in
    
            guard let result = result?.toDictionary() else { return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectExpenseItemResponse.value)) }
                
            return deserializeArray(json: result,
                                    incorrectJsonError: MSError.genericError(errorText: LocalizedStrings.incorrectExpenseItemResponse.value),
                                    deserializer: { MSExpenseItem.from(dict: $0) })
        }
    }
    
    public static func loadCountries(auth: Auth,
                                        offset: MSOffset? = nil,
                                        expanders: [Expander] = [],
                                        filter: Filter? = nil,
                                        search: Search? = nil) -> Observable<[MSEntity<MSCountry>]> {
        let urlParameters: [UrlParameter] = mergeUrlParameters(offset, filter, search, CompositeExpander(expanders))
        return HttpClient.get(.country, auth: auth, urlParameters: urlParameters)
            .flatMapLatest { result -> Observable<[MSEntity<MSCountry>]> in
                
                guard let result = result?.toDictionary() else { return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectCountiesResponse.value)) }
                
                return deserializeArray(json: result,
                                        incorrectJsonError: MSError.genericError(errorText: LocalizedStrings.incorrectCountiesResponse.value),
                                        deserializer: { MSCountry.from(dict: $0) })
        }
    }
    
    public static func loadUom(auth: Auth,
                                     offset: MSOffset? = nil,
                                     expanders: [Expander] = [],
                                     filter: Filter? = nil,
                                     search: Search? = nil) -> Observable<[MSEntity<MSUOM>]> {
        let urlParameters: [UrlParameter] = mergeUrlParameters(offset, filter, search, CompositeExpander(expanders))
        return HttpClient.get(.uom, auth: auth, urlParameters: urlParameters)
            .flatMapLatest { result -> Observable<[MSEntity<MSUOM>]> in
                
                guard let result = result?.toDictionary() else { return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectUomResponse.value)) }
                
                return deserializeArray(json: result,
                                        incorrectJsonError: MSError.genericError(errorText: LocalizedStrings.incorrectUomResponse.value),
                                        deserializer: { MSUOM.from(dict: $0) })
        }
    }
    
    /**
    Load Variant metadata
    - parameter auth: Authentication information
    - returns: Metadata for object
    */
    public static func variantMetadata(auth: Auth,
                                       offset: MSOffset? = nil,
                                       expanders: [Expander] = [],
                                       filter: Filter? = nil,
                                       search: Search? = nil) -> Observable<[MSEntity<MSVariantAttribute>]> {
        return HttpClient.get(.variantMetadata, auth: auth)
            .flatMapLatest { result -> Observable<[MSEntity<MSVariantAttribute>]> in
                guard let result = result?.toDictionary() else {
                    return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectVariantMetadataResponse.value))
                }
                
                let deserialized = result.msArray("characteristics").map { MSVariantAttribute.from(dict: $0) }
                let withoutNills = deserialized.removeNils()
                
                return .just(withoutNills)
        }
    }
    
    /**
     Load Variants.
     Also see [ API reference](https://online.moysklad.ru/api/remap/1.1/doc/index.html#модификация-модификации)
     - parameter auth: Authentication information
     - parameter offset: Desired data offset
     - parameter expanders: Additional objects to include into request
     - parameter filter: Filter for request
     - parameter search: Additional string for filtering by name
     - returns: Collection of Variant
     */
    public static func variants(auth: Auth,
                                offset: MSOffset? = nil,
                                expanders: [Expander] = [],
                                filter: Filter? = nil,
                                search: Search? = nil)
        -> Observable<[MSEntity<MSAssortment>]> {
            
            let urlParameters: [UrlParameter] = mergeUrlParameters(offset, filter, search, CompositeExpander(expanders))
            
            return HttpClient.get(.variant, auth: auth, urlParameters: urlParameters)
                .flatMapLatest { result -> Observable<[MSEntity<MSAssortment>]> in
                    guard let result = result?.toDictionary() else {
                        return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectVariantResponse.value))
                    }
                    
                    let deserialized = result.msArray("rows").map { MSAssortment.from(dict: $0) }
                    let withoutNills = deserialized.removeNils()
                    
                    guard withoutNills.count == deserialized.count else {
                        return Observable.error(MSError.genericError(errorText: LocalizedStrings.incorrectVariantResponse.value))
                    }
                    
                    return Observable.just(withoutNills)
            }
    }
    
    public static func downloadFile(auth: Auth, url: URL) -> Observable<URL> {
        var request = URLRequest(url: url)
        request.addValue(auth.header.values.first!, forHTTPHeaderField: auth.header.keys.first!)
        return HttpClient.resultCreateForDownloadFile(request)
    }
}
