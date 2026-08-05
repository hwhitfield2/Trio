enum MLEngineData {
    enum Config {}
}

protocol MLEngineDataProvider {}
extension MLEngineData {
    final class Provider: BaseProvider, MLEngineDataProvider {}
}
